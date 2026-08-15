#!/usr/bin/env bash
# =============================================================================
# Turnstone Repository Cluster Sync Tool
#
# Synchronizes the local Turnstone repository copy to LLM cluster nodes via rsync
# over passwordless SSH authentication.
#
# Configured Cluster Nodes:
#   1. postgres    -> postgres@turnstone-postgres.lan:~/nerd_projects/turnstone-teqonix
#   2. coordinator -> turnstone@turnstone-coordinator-nerd-projects.lan:~/nerd_projects/turnstone-teqonix
#
# Usage:
#   ./scripts/sync_repo.sh                      # Sync to ALL cluster nodes (default)
#   ./scripts/sync_repo.sh postgres             # Sync to postgres node only
#   ./scripts/sync_repo.sh coordinator          # Sync to coordinator node only
#   ./scripts/sync_repo.sh --target postgres    # Target explicitly by flag
#   ./scripts/sync_repo.sh --interactive (-i)   # Interactively pick target node(s)
#   ./scripts/sync_repo.sh --dry-run (-n)       # Preview changes without copying
#   ./scripts/sync_repo.sh --delete (-d)        # Delete remote files not present locally
#   ./scripts/sync_repo.sh --list (-l)          # List configured cluster nodes
# =============================================================================

set -euo pipefail

# Color Codes for Output Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Helper Logging Functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() {
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
}

# Resolve Repository Root reliably (resolves symlinks if invoked via root link)
REAL_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${REAL_SOURCE}")" && pwd)"
if git rev-parse --show-toplevel &>/dev/null; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Target Cluster Nodes Definition
# Format: KEY | HOST | USER | DEST_REL_PATH | DESCRIPTION
NODE_KEYS=("postgres" "coordinator")

node_host() {
    case "$1" in
        postgres) echo "turnstone-postgres.lan" ;;
        coordinator) echo "turnstone-coordinator-nerd-projects.lan" ;;
        *) echo "" ;;
    esac
}

node_user() {
    case "$1" in
        postgres) echo "postgres" ;;
        coordinator) echo "turnstone" ;;
        *) echo "" ;;
    esac
}

node_dest() {
    case "$1" in
        postgres|coordinator) echo "~/nerd_projects/turnstone-teqonix" ;;
        *) echo "" ;;
    esac
}

node_desc() {
    case "$1" in
        postgres) echo "PostgreSQL Database Node (turnstone-postgres.lan)" ;;
        coordinator) echo "Coordinator Stack Node (turnstone-coordinator-nerd-projects.lan)" ;;
        *) echo "" ;;
    esac
}

# Options & Flags Defaults
TARGET_CHOICE="all"
DRY_RUN=false
DELETE_REMOTE=false
INTERACTIVE=false
VERBOSE=false
EXCLUDE_GIT=false
EXTRA_RSYNC_ARGS=()

show_usage() {
    cat <<EOF
${BOLD}Turnstone Repository Cluster Sync Tool${NC}

${BOLD}USAGE:${NC}
  $(basename "$0") [OPTIONS] [TARGET]

${BOLD}TARGETS:${NC}
  all           Sync to ALL cluster nodes (Default)
  postgres      Sync to postgres@turnstone-postgres.lan
  coordinator   Sync to turnstone@turnstone-coordinator-nerd-projects.lan

${BOLD}OPTIONS:${NC}
  -t, --target <node>    Specify target node ('postgres', 'coordinator', or 'all')
  -i, --interactive      Prompt for node selection interactively
  -n, --dry-run          Perform a trial run with no changes made to remote
  -d, --delete           Delete extraneous files from destination directories
  -l, --list             List all configured cluster nodes
  -v, --verbose          Increase rsync output verbosity
  --exclude-git          Exclude .git directory from sync
  -h, --help             Show this help message

${BOLD}EXAMPLES:${NC}
  # Sync repo to all nodes (default)
  $(basename "$0")

  # Sync repo to turnstone-postgres.lan only
  $(basename "$0") postgres

  # Perform a dry-run sync to coordinator node
  $(basename "$0") coordinator --dry-run

  # Interactively choose node and sync with delete option
  $(basename "$0") -i -d
EOF
}

list_nodes() {
    echo -e "${BOLD}Configured Turnstone Cluster Nodes:${NC}"
    echo -e "${CYAN}=================================================================${NC}"
    printf "%-4s %-15s %-12s %-42s %-35s\n" "#" "KEY" "USER" "HOST" "DESTINATION PATH"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    local idx=1
    for key in "${NODE_KEYS[@]}"; do
        printf "%-4d %-15s %-12s %-42s %-35s\n" \
            "$idx" "$key" "$(node_user "$key")" "$(node_host "$key")" "$(node_dest "$key")"
        idx=$((idx + 1))
    done
    echo -e "${CYAN}=================================================================${NC}"
}

# Parse Command Line Arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -l|--list)
                list_nodes
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -d|--delete)
                DELETE_REMOTE=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --exclude-git)
                EXCLUDE_GIT=true
                shift
                ;;
            -t|--target)
                if [[ -n "${2:-}" ]]; then
                    TARGET_CHOICE="$2"
                    shift 2
                else
                    log_error "Option --target requires an argument."
                    exit 1
                fi
                ;;
            all|postgres|coordinator|turnstone-postgres|turnstone-postgres.lan|turnstone-coordinator|turnstone-coordinator-nerd-projects.lan|1|2)
                TARGET_CHOICE="$1"
                shift
                ;;
            *)
                log_error "Unknown argument or target: $1"
                echo "Use --help to see available options and targets."
                exit 1
                ;;
        esac
    done
}

# Normalize target choice into list of valid node keys
resolve_targets() {
    local choice="$1"
    case "$choice" in
        all)
            SELECTED_TARGETS=("postgres" "coordinator")
            ;;
        postgres|turnstone-postgres|turnstone-postgres.lan|1)
            SELECTED_TARGETS=("postgres")
            ;;
        coordinator|turnstone-coordinator|turnstone-coordinator-nerd-projects.lan|2)
            SELECTED_TARGETS=("coordinator")
            ;;
        *)
            log_error "Invalid target selection: '${choice}'."
            exit 1
            ;;
    esac
}

prompt_interactive() {
    echo -e "${BOLD}Interactive Node Selection:${NC}"
    echo "1) All Cluster Nodes"
    echo "2) postgres    (turnstone-postgres.lan)"
    echo "3) coordinator (turnstone-coordinator-nerd-projects.lan)"
    echo
    read -rp "Select target node [1-3] (Default: 1): " choice
    choice="${choice:-1}"
    case "$choice" in
        1|all) TARGET_CHOICE="all" ;;
        2|postgres) TARGET_CHOICE="postgres" ;;
        3|coordinator) TARGET_CHOICE="coordinator" ;;
        *)
            log_error "Invalid selection: $choice"
            exit 1
            ;;
    esac
}

# Sync execution logic for a single target node
sync_to_node() {
    local key="$1"
    local host
    local user
    local dest_dir
    local desc

    host="$(node_host "$key")"
    user="$(node_user "$key")"
    dest_dir="$(node_dest "$key")"
    desc="$(node_desc "$key")"

    log_section "Syncing to ${desc}"
    log_info "Source:      ${REPO_ROOT}/"
    log_info "Destination: ${user}@${host}:${dest_dir}/"

    # Step 1: Verify Passwordless SSH Connection & Target Directory
    log_info "Testing SSH connection to ${user}@${host}..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=6 "${user}@${host}" "mkdir -p ${dest_dir}" &>/dev/null; then
        log_error "Failed to connect via passwordless SSH to ${user}@${host}."
        log_error "Please check network connectivity, hostname resolution, and SSH key authentication."
        return 1
    fi
    log_success "SSH connection verified to ${host}."

    # Step 2: Assemble Rsync Command
    local rsync_cmd=(rsync -az --progress --human-readable)

    if [ "$DRY_RUN" = true ]; then
        rsync_cmd+=(--dry-run)
        log_warn "DRY RUN MODE ENABLED - No files will be modified on remote host."
    fi

    if [ "$DELETE_REMOTE" = true ]; then
        rsync_cmd+=(--delete)
        log_warn "DELETE MODE ENABLED - Remote destination will be purged of extra files."
    fi

    if [ "$VERBOSE" = true ]; then
        rsync_cmd+=(-v)
    fi

    if [ "$EXCLUDE_GIT" = true ]; then
        rsync_cmd+=(--exclude='.git/')
    fi

    # Standard exclusions for python build artifacts and venvs
    rsync_cmd+=(
        --exclude='.venv'
        --exclude='venv'
        --exclude='__pycache__'
        --exclude='*.pyc'
        --exclude='.pytest_cache'
        --exclude='.ruff_cache'
        --exclude='.mypy_cache'
        --exclude='.DS_Store'
    )

    # Add source path and destination path
    rsync_cmd+=("${REPO_ROOT}/" "${user}@${host}:${dest_dir}/")

    # Step 3: Run Rsync
    log_info "Running rsync command:"
    echo -e "${CYAN}${rsync_cmd[*]}${NC}"
    echo

    if "${rsync_cmd[@]}"; then
        log_success "Successfully synced repo to ${user}@${host}:${dest_dir}/"
        return 0
    else
        log_error "Rsync failed for node ${host}."
        return 1
    fi
}

main() {
    parse_args "$@"

    if [ "$INTERACTIVE" = true ]; then
        prompt_interactive
    fi

    resolve_targets "$TARGET_CHOICE"

    echo -e "${BLUE}=================================================================${NC}"
    echo -e "${BLUE}         Turnstone LLM Cluster Repository Sync                  ${NC}"
    echo -e "${BLUE}=================================================================${NC}"
    log_info "Local Repo Root: ${REPO_ROOT}"
    log_info "Target Nodes:    ${SELECTED_TARGETS[*]}"
    if [ "$DRY_RUN" = true ]; then
        log_warn "Mode:            DRY-RUN (Simulation only)"
    else
        log_info "Mode:            LIVE SYNC"
    fi

    local successes=()
    local failures=()

    for node_key in "${SELECTED_TARGETS[@]}"; do
        if sync_to_node "$node_key"; then
            successes+=("$node_key")
        else
            failures+=("$node_key")
        fi
        echo
    done

    # Final Summary Report
    log_section "Cluster Sync Summary"
    if [ ${#successes[@]} -gt 0 ]; then
        log_success "Successfully synced targets (${#successes[@]}): ${successes[*]}"
    fi

    if [ ${#failures[@]} -gt 0 ]; then
        log_error "Failed targets (${#failures[@]}): ${failures[*]}"
        exit 1
    fi

    log_success "All cluster sync tasks completed successfully!"
}

main "$@"
