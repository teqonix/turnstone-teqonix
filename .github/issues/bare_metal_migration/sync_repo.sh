#!/usr/bin/env bash
# =============================================================================
# Turnstone Repository Cluster Sync Tool
#
# Synchronizes the local Turnstone repository copy to LLM cluster nodes via rsync
# over passwordless SSH authentication. Automatically provisions SSH keys from
# secret credentials and ensures rsync is installed on remote targets.
#
# Configured Cluster Nodes:
#   1. postgres    -> postgres@turnstone-postgres.lan:~/nerd_projects/turnstone-teqonix
#   2. coordinator -> turnstone@turnstone-coordinator-nerd-projects.lan:~/nerd_projects/turnstone-teqonix
#   3. ai-core-one -> turnstone@amd-ai-core-one.lan:~/nerd_projects/turnstone-teqonix
#   4. ai-core-two -> turnstone@amd-ai-core-two.lan:~/nerd_projects/turnstone-teqonix
#   5. mbp-ai-core -> turnstone@mbp-ai-core.lan:~/nerd_projects/turnstone-teqonix
#   6. litellm     -> turnstone@litellm-proxy.lan:~/nerd_projects/turnstone-teqonix
#
# Usage:
#   ./sync_repo.sh                      # Sync to ALL cluster nodes (default)
#   ./sync_repo.sh litellm              # Sync to LiteLLM proxy node only
#   ./sync_repo.sh postgres             # Sync to postgres node only
#   ./sync_repo.sh coordinator          # Sync to coordinator node only
#   ./sync_repo.sh --target litellm     # Target explicitly by flag
#   ./sync_repo.sh --interactive (-i)   # Interactively pick target node(s)
#   ./sync_repo.sh --dry-run (-n)       # Preview changes without copying
#   ./sync_repo.sh --delete (-d)        # Delete remote files not present locally
#   ./sync_repo.sh --list (-l)          # List configured cluster nodes
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
NODE_KEYS=("postgres" "coordinator" "ai-core-one" "ai-core-two" "mbp-ai-core" "litellm")

node_host() {
    case "$1" in
        postgres) echo "turnstone-postgres.lan" ;;
        coordinator) echo "turnstone-coordinator-nerd-projects.lan" ;;
        ai-core-one) echo "amd-ai-core-one.lan" ;;
        ai-core-two) echo "amd-ai-core-two.lan" ;;
        mbp-ai-core) echo "mbp-ai-core.lan" ;;
        litellm|litellm-proxy) echo "litellm-proxy.lan" ;;
        *) echo "" ;;
    esac
}

node_user() {
    case "$1" in
        postgres) echo "postgres" ;;
        coordinator|ai-core-one|ai-core-two|mbp-ai-core|litellm|litellm-proxy) echo "turnstone" ;;
        *) echo "" ;;
    esac
}

node_dest() {
    case "$1" in
        postgres|coordinator|ai-core-one|ai-core-two|mbp-ai-core|litellm|litellm-proxy) echo "~/nerd_projects/turnstone-teqonix" ;;
        *) echo "" ;;
    esac
}

node_desc() {
    case "$1" in
        postgres) echo "PostgreSQL Database Node (turnstone-postgres.lan)" ;;
        coordinator) echo "Coordinator Stack Node (turnstone-coordinator-nerd-projects.lan)" ;;
        ai-core-one) echo "Ryzen AI Halo Worker Node #1 (amd-ai-core-one.lan)" ;;
        ai-core-two) echo "Ryzen AI Halo Worker Node #2 (amd-ai-core-two.lan)" ;;
        mbp-ai-core) echo "Apple M5 Max MLX Worker Node (mbp-ai-core.lan)" ;;
        litellm|litellm-proxy) echo "LiteLLM Proxy Load Balancer Node (litellm-proxy.lan)" ;;
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
  ai-core-one   Sync to turnstone@amd-ai-core-one.lan
  ai-core-two   Sync to turnstone@amd-ai-core-two.lan
  mbp-ai-core   Sync to turnstone@mbp-ai-core.lan
  litellm       Sync to turnstone@litellm-proxy.lan

${BOLD}OPTIONS:${NC}
  -t, --target <node>    Specify target node ('postgres', 'coordinator', 'ai-core-one', 'ai-core-two', 'mbp-ai-core', 'litellm', or 'all')
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

  # Sync repo to litellm proxy only
  $(basename "$0") litellm

  # Sync repo to amd-ai-core-one.lan only
  $(basename "$0") ai-core-one

  # Sync repo to mbp-ai-core.lan
  $(basename "$0") mbp-ai-core

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
            all|postgres|coordinator|turnstone-postgres|turnstone-postgres.lan|turnstone-coordinator|turnstone-coordinator-nerd-projects.lan|ai-core-one|amd-ai-core-one|amd-ai-core-one.lan|ai-core-two|amd-ai-core-two|amd-ai-core-two.lan|mbp-ai-core|mbp-ai-core.lan|litellm|litellm-proxy|litellm-proxy.lan|1|2|3|4|5|6)
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
            SELECTED_TARGETS=("postgres" "coordinator" "ai-core-one" "ai-core-two" "mbp-ai-core" "litellm")
            ;;
        postgres|turnstone-postgres|turnstone-postgres.lan|1)
            SELECTED_TARGETS=("postgres")
            ;;
        coordinator|turnstone-coordinator|turnstone-coordinator-nerd-projects.lan|2)
            SELECTED_TARGETS=("coordinator")
            ;;
        ai-core-one|amd-ai-core-one|amd-ai-core-one.lan|3)
            SELECTED_TARGETS=("ai-core-one")
            ;;
        ai-core-two|amd-ai-core-two|amd-ai-core-two.lan|4)
            SELECTED_TARGETS=("ai-core-two")
            ;;
        mbp-ai-core|mbp-ai-core.lan|5)
            SELECTED_TARGETS=("mbp-ai-core")
            ;;
        litellm|litellm-proxy|litellm-proxy.lan|6)
            SELECTED_TARGETS=("litellm")
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
    echo "4) ai-core-one  (amd-ai-core-one.lan)"
    echo "5) ai-core-two  (amd-ai-core-two.lan)"
    echo "6) mbp-ai-core  (mbp-ai-core.lan)"
    echo "7) litellm      (litellm-proxy.lan)"
    echo
    read -rp "Select target node [1-7] (Default: 1): " choice
    choice="${choice:-1}"
    case "$choice" in
        1|all) TARGET_CHOICE="all" ;;
        2|postgres) TARGET_CHOICE="postgres" ;;
        3|coordinator) TARGET_CHOICE="coordinator" ;;
        4|ai-core-one|amd-ai-core-one) TARGET_CHOICE="ai-core-one" ;;
        5|ai-core-two|amd-ai-core-two) TARGET_CHOICE="ai-core-two" ;;
        6|mbp-ai-core) TARGET_CHOICE="mbp-ai-core" ;;
        7|litellm|litellm-proxy) TARGET_CHOICE="litellm" ;;
        *)
            log_error "Invalid selection: $choice"
            exit 1
            ;;
    esac
}

# Locate secret credential file for a target node
find_secret_for_node() {
    local key="$1"
    local search_dirs=(
        "${SCRIPT_DIR}/secrets"
        "${REPO_ROOT}/secrets"
        "${REPO_ROOT}/.github/issues/bare_metal_migration/secrets"
        "${SCRIPT_DIR}"
    )

    local candidate_names=()
    case "$key" in
        litellm|litellm-proxy)
            candidate_names=("litellm_turnstone.secret" "litellm.secret" "litellm_proxy.secret")
            ;;
        postgres)
            candidate_names=("postgres_admin.secret" "postgres.secret" "postgres_postgres.secret")
            ;;
        coordinator)
            candidate_names=("coordinator.secret" "coordinator_turnstone.secret" "turnstone.secret")
            ;;
        *)
            candidate_names=("${key}.secret" "${key}_turnstone.secret")
            ;;
    esac

    for sdir in "${search_dirs[@]}"; do
        [ -d "$sdir" ] || continue
        for cname in "${candidate_names[@]}"; do
            if [ -f "${sdir}/${cname}" ]; then
                echo "${sdir}/${cname}"
                return 0
            fi
        done
        for f in "${sdir}/${key}"*.secret "${sdir}"/*"${key}"*.secret; do
            if [ -f "$f" ]; then
                echo "$f"
                return 0
            fi
        done
    done
    return 1
}

# Parse connection string from a secret file (e.g. ssh://user:pass@host:port)
parse_secret_credentials() {
    local secret_file="$1"
    [ -f "$secret_file" ] || return 1

    python3 -c "
import urllib.parse
with open('${secret_file}') as f:
    content = f.read().strip()
lines = [l.strip() for l in content.splitlines() if l.strip() and not l.strip().startswith('#')]
conn_str = ''
for line in lines:
    if line.startswith('ssh://') or '://' in line or '@' in line:
        conn_str = line
        break
if not conn_str and lines:
    conn_str = lines[0]

if '://' not in conn_str and '@' in conn_str:
    conn_str = 'ssh://' + conn_str
elif '://' not in conn_str:
    conn_str = 'ssh://' + conn_str

parsed = urllib.parse.urlparse(conn_str)
user = parsed.username or ''
password = parsed.password or ''
host = parsed.hostname or ''
port = str(parsed.port or 22)
print(f'{user}|{password}|{host}|{port}')
" 2>/dev/null || true
}

# Ensure local user has an SSH public key available
ensure_local_ssh_key() {
    local pub_keys=(~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub)
    for k in "${pub_keys[@]}"; do
        if [ -f "$k" ]; then
            return 0
        fi
    done
    log_info "No local SSH public key found. Generating ~/.ssh/id_ed25519..."
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "turnstone-sync-$(whoami)@$(hostname)"
}

# Setup passwordless SSH authentication using credentials in secret file
setup_ssh_key_auth() {
    local key="$1"
    local host="$2"
    local user="$3"

    local secret_file
    secret_file="$(find_secret_for_node "$key" || true)"

    if [ -z "$secret_file" ] || [ ! -f "$secret_file" ]; then
        return 1
    fi

    local creds
    creds="$(parse_secret_credentials "$secret_file")"
    local s_user s_pass s_host s_port
    IFS='|' read -r s_user s_pass s_host s_port <<< "$creds"

    local target_user="${s_user:-$user}"
    local target_host="${s_host:-$host}"
    local target_port="${s_port:-22}"
    local target_pass="${s_pass:-}"

    if [ -z "$target_pass" ]; then
        return 1
    fi

    ensure_local_ssh_key
    log_info "Attempting one-time password auth via ssh-copy-id using '$(basename "$secret_file")'..."

    # Method 1: expect
    if command -v expect &>/dev/null; then
        local expect_cmd
        expect_cmd=$(cat <<EOF
set timeout 25
spawn ssh-copy-id -o StrictHostKeyChecking=accept-new -p ${target_port} ${target_user}@${target_host}
expect {
    "*yes/no*" { send "yes\r"; exp_continue }
    "*password:*" { send "${target_pass}\r" }
    "*Password:*" { send "${target_pass}\r" }
}
expect eof
EOF
)
        expect -c "$expect_cmd" &>/dev/null || true

    # Method 2: sshpass
    elif command -v sshpass &>/dev/null; then
        sshpass -p "$target_pass" ssh-copy-id -o StrictHostKeyChecking=accept-new -p "$target_port" "${target_user}@${target_host}" &>/dev/null || true

    # Method 3: python pty fallback
    elif command -v python3 &>/dev/null; then
        python3 -c "
import pty, os, sys, time
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.execvp('ssh-copy-id', ['ssh-copy-id', '-o', 'StrictHostKeyChecking=accept-new', '-p', '$target_port', '${target_user}@${target_host}'])
else:
    os.close(slave)
    out = b''
    for _ in range(50):
        try:
            chunk = os.read(master, 1024)
            if not chunk: break
            out += chunk
            if b'yes/no' in out:
                os.write(master, b'yes\n')
                out = b''
            elif b'password:' in out.lower() or b'password' in out.lower():
                os.write(master, b'$target_pass\n')
                time.sleep(1)
                break
        except OSError:
            break
    try: os.waitpid(pid, 0)
    except: pass
" &>/dev/null || true
    fi

    # Verify if SSH key authentication succeeded
    if ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -p "$target_port" "${target_user}@${target_host}" "true" &>/dev/null; then
        log_success "Passwordless SSH key authentication established for ${target_user}@${target_host}."
        return 0
    else
        return 1
    fi
}

# Verify and ensure passwordless SSH connection
ensure_ssh_connection() {
    local key="$1"
    local host="$2"
    local user="$3"

    log_info "Testing SSH connection to ${user}@${host}..."
    if ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "${user}@${host}" "true" &>/dev/null; then
        log_success "SSH connection verified to ${host}."
        return 0
    fi

    log_warn "Passwordless SSH connection to ${user}@${host} not yet configured."
    if setup_ssh_key_auth "$key" "$host" "$user"; then
        return 0
    fi

    log_error "Failed to connect via passwordless SSH to ${user}@${host}."
    log_error "Please check network connectivity, hostname resolution, and SSH key authentication."
    return 1
}

# Ensure rsync is installed on the remote target host
ensure_remote_rsync() {
    local key="$1"
    local host="$2"
    local user="$3"

    if ssh -o BatchMode=yes -o ConnectTimeout=6 "${user}@${host}" "command -v rsync" &>/dev/null; then
        return 0
    fi

    log_warn "rsync is not installed on remote host '${host}'. Installing rsync..."

    # Retrieve password if available from secret file for sudo fallback
    local secret_file
    secret_file="$(find_secret_for_node "$key" || true)"
    local target_pass=""
    if [ -n "$secret_file" ] && [ -f "$secret_file" ]; then
        local creds
        creds="$(parse_secret_credentials "$secret_file")"
        IFS='|' read -r _ target_pass _ _ <<< "$creds"
    fi

    local install_script
    install_script=$(cat <<'EOF'
set -e
if command -v rsync &>/dev/null; then
    exit 0
fi

if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    if sudo -n true 2>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq rsync
    elif [ -n "__PASSWORD__" ]; then
        echo "__PASSWORD__" | sudo -S apt-get update -qq && echo "__PASSWORD__" | sudo -S apt-get install -y -qq rsync
    elif [ "$(id -u)" -eq 0 ]; then
        apt-get update -qq && apt-get install -y -qq rsync
    fi
elif command -v apk &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        sudo apk add --no-cache rsync
    elif [ -n "__PASSWORD__" ]; then
        echo "__PASSWORD__" | sudo -S apk add --no-cache rsync
    else
        apk add --no-cache rsync
    fi
elif command -v dnf &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        sudo dnf install -y rsync
    elif [ -n "__PASSWORD__" ]; then
        echo "__PASSWORD__" | sudo -S dnf install -y rsync
    else
        dnf install -y rsync
    fi
elif command -v yum &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        sudo yum install -y rsync
    elif [ -n "__PASSWORD__" ]; then
        echo "__PASSWORD__" | sudo -S yum install -y rsync
    else
        yum install -y rsync
    fi
elif command -v pacman &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        sudo pacman -Sy --noconfirm rsync
    elif [ -n "__PASSWORD__" ]; then
        echo "__PASSWORD__" | sudo -S pacman -Sy --noconfirm rsync
    else
        pacman -Sy --noconfirm rsync
    fi
elif command -v brew &>/dev/null; then
    brew install rsync
fi
command -v rsync &>/dev/null
EOF
)

    install_script="${install_script//__PASSWORD__/${target_pass}}"

    if ssh -o BatchMode=yes -o ConnectTimeout=20 "${user}@${host}" "bash -c $(printf %q "$install_script")"; then
        log_success "rsync installed successfully on ${host}."
        return 0
    else
        log_error "Failed to install rsync on ${host}. Please install rsync manually on remote host."
        return 1
    fi
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

    # Step 1: Verify Passwordless SSH Connection
    if ! ensure_ssh_connection "$key" "$host" "$user"; then
        return 1
    fi

    # Step 2: Ensure rsync is installed on remote host
    if ! ensure_remote_rsync "$key" "$host" "$user"; then
        return 1
    fi

    # Step 3: Ensure destination directory exists on remote host
    if ! ssh -o BatchMode=yes -o ConnectTimeout=6 "${user}@${host}" "mkdir -p ${dest_dir}" &>/dev/null; then
        log_error "Failed to create remote directory ${dest_dir} on ${host}."
        return 1
    fi

    # Step 4: Assemble Rsync Command
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

    # Step 5: Run Rsync
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
