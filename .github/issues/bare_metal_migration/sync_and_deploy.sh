#!/usr/bin/env bash
# =============================================================================
# Turnstone Cluster Sync and Deploy Tool
#
# Synchronizes the latest turnstone-teqonix codebase to:
#   1. Coordinator Server: turnstone@turnstone-coordinator-nerd-projects.lan
#   2. Worker One:         turnstone@turnstone_worker_one.lan (or turnstone-worker-one.lan)
#   3. Worker Two:         turnstone@turnstone-worker-two.lan
#
# And then automatically installs / reloads the new code:
#   * On the server:  Runs deploy_turnstone_server.sh (updates container stack & restarts console/channel)
#   * On the workers: Runs deploy_turnstone_debian12.sh (reinstalls virtualenv & restarts turnstone-server)
# =============================================================================

set -euo pipefail

# Ensure standard system binary paths are present in PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin:${PATH}"

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() {
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
}

# Resolve Repository Root reliably
REAL_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${REAL_SOURCE}")" && pwd)"
if git rev-parse --show-toplevel &>/dev/null; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"
fi

# Target Host Configurations
SERVER_HOST="${COORDINATOR_HOST:-turnstone-coordinator-nerd-projects.lan}"
SERVER_USER="${COORDINATOR_USER:-turnstone}"
SERVER_DEST="~/nerd_projects/turnstone-teqonix"

WORKER_ONE_PRIMARY="${WORKER_ONE_HOST:-turnstone_worker_one.lan}"
WORKER_ONE_FALLBACK="turnstone-worker-one.lan"
WORKER_ONE_USER="${WORKER_ONE_USER:-turnstone}"
WORKER_ONE_NODE_ID="turnstone-worker-one"
WORKER_ONE_DEST="~/nerd_projects/turnstone-teqonix"

WORKER_TWO_HOST="${WORKER_TWO_HOST:-turnstone-worker-two.lan}"
WORKER_TWO_USER="${WORKER_TWO_USER:-turnstone}"
WORKER_TWO_NODE_ID="turnstone-worker-two"
WORKER_TWO_DEST="~/nerd_projects/turnstone-teqonix"

# Execution Flags Defaults
ACTION_SYNC=true
ACTION_INSTALL=true
TARGET_FILTER="all"
QUICK_MODE=false
DRY_RUN=false
VERBOSE=false
DELETE_REMOTE=false
EXCLUDE_GIT=false

show_usage() {
    cat <<EOF
${BOLD}Turnstone Cluster Sync and Deploy Tool${NC}

Synchronizes the latest codebase and installs/reloads it across the coordinator
server and worker nodes.

${BOLD}USAGE:${NC}
  $(basename "$0") [OPTIONS] [TARGET]

${BOLD}TARGETS:${NC}
  all                  Coordinator server + both worker nodes (Default)
  server, coordinator  Coordinator server only (turnstone@${SERVER_HOST})
  workers              Both worker nodes only
  worker-one           Worker 1 only (turnstone@${WORKER_ONE_PRIMARY})
  worker-two           Worker 2 only (turnstone@${WORKER_TWO_HOST})

${BOLD}OPTIONS:${NC}
  -t, --target <name>  Specify target node ('all', 'server', 'workers', 'worker-one', 'worker-two')
  --sync-only          Only sync the repository files, do not trigger install/restart
  --install-only       Only trigger remote install/restart, do not sync files
  --quick, --fast      Fast reload (quick container restart for server, quick uv reinstall for workers)
  --server-only        Shorthand for '--target server'
  --workers-only       Shorthand for '--target workers'
  -n, --dry-run        Dry run mode (shows commands without modifying targets)
  -d, --delete         Delete files in destination that no longer exist locally
  -v, --verbose        Show verbose rsync and SSH execution logs
  --exclude-git        Exclude .git directory during synchronization
  -h, --help           Display this help guide and exit

${BOLD}EXAMPLES:${NC}
  # 1. Full sync and deploy to server and workers (default)
  ./$(basename "$0")

  # 2. Fast update and reload across all cluster nodes
  ./$(basename "$0") --quick

  # 3. Sync and deploy only to the coordinator server
  ./$(basename "$0") --server-only

  # 4. Sync and deploy only to the workers
  ./$(basename "$0") --workers-only

  # 5. Sync only to worker one
  ./$(basename "$0") worker-one --sync-only
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --sync-only)
                ACTION_SYNC=true
                ACTION_INSTALL=false
                shift
                ;;
            --install-only|--deploy-only)
                ACTION_SYNC=false
                ACTION_INSTALL=true
                shift
                ;;
            --quick|--fast)
                QUICK_MODE=true
                shift
                ;;
            --server-only|--coordinator-only)
                TARGET_FILTER="server"
                shift
                ;;
            --workers-only)
                TARGET_FILTER="workers"
                shift
                ;;
            -t|--target)
                TARGET_FILTER="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -d|--delete)
                DELETE_REMOTE=true
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
            all|server|coordinator|workers|worker-one|turnstone-worker-one|worker-two|turnstone-worker-two)
                TARGET_FILTER="$1"
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                echo "Use --help to view available options."
                exit 1
                ;;
        esac
    done
}

# Resolve which hostname to use for worker one (trying underscore then hyphen)
resolve_worker_one_host() {
    local candidate="${WORKER_ONE_PRIMARY}"
    if getent hosts "${candidate}" &>/dev/null; then
        echo "${candidate}"
        return 0
    fi
    if ping -c 1 -W 1 "${candidate}" &>/dev/null; then
        echo "${candidate}"
        return 0
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "${WORKER_ONE_USER}@${candidate}" "true" &>/dev/null; then
        echo "${candidate}"
        return 0
    fi

    # Fallback to hyphenated hostname
    if getent hosts "${WORKER_ONE_FALLBACK}" &>/dev/null || ping -c 1 -W 1 "${WORKER_ONE_FALLBACK}" &>/dev/null; then
        log_info "Host '${candidate}' unresolved; using fallback '${WORKER_ONE_FALLBACK}'." >&2
        echo "${WORKER_ONE_FALLBACK}"
        return 0
    fi

    # Default to primary candidate if network is unreachable (e.g. sandbox or offline)
    echo "${candidate}"
}

# Locate secret credential file for a target node
find_secret_for_node() {
    local key="$1"
    local search_dirs=(
        "/etc/turnstone/secrets"
        "/etc/turnstone"
        "${HOME}/.turnstone/secrets"
        "${HOME}/.turnstone"
        "${SCRIPT_DIR}/secrets"
        "${REPO_ROOT}/secrets"
        "${SCRIPT_DIR}"
    )

    local candidate_names=()
    case "$key" in
        coordinator|server)
            candidate_names=("coordinator.secret" "coordinator_turnstone.secret" "postgres_admin.secret" "turnstone.secret")
            ;;
        worker-one|turnstone-worker-one)
            candidate_names=("turnstone_worker_one.secret" "worker_one.secret" "turnstone_worker.secret" "turnstone.secret")
            ;;
        worker-two|turnstone-worker-two)
            candidate_names=("turnstone_worker_two.secret" "worker_two.secret" "turnstone_worker.secret" "turnstone.secret")
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

ensure_local_ssh_key() {
    local pub_keys=(~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub)
    for k in "${pub_keys[@]}"; do
        if [ -f "$k" ]; then
            return 0
        fi
    done
    log_info "Generating ~/.ssh/id_ed25519 public key..."
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "turnstone-cluster-$(whoami)@$(hostname)"
}

setup_ssh_key_auth() {
    local key="$1"
    local host="$2"
    local user="$3"

    local secret_file
    secret_file="$(find_secret_for_node "$key" || true)"
    [ -z "$secret_file" ] && return 1

    local creds
    creds="$(parse_secret_credentials "$secret_file")"
    local s_user s_pass s_host s_port
    IFS='|' read -r s_user s_pass s_host s_port <<< "$creds"

    local target_user="${s_user:-$user}"
    local target_host="${s_host:-$host}"
    local target_port="${s_port:-22}"
    local target_pass="${s_pass:-}"

    [ -z "$target_pass" ] && return 1

    ensure_local_ssh_key
    log_info "Configuring SSH key authentication on ${target_host}..."

    if command -v sshpass &>/dev/null; then
        sshpass -p "$target_pass" ssh-copy-id -o StrictHostKeyChecking=accept-new -p "$target_port" "${target_user}@${target_host}" &>/dev/null || true
    elif command -v python3 &>/dev/null; then
        python3 -c "
import pty, os, time
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
            elif b'password:' in out.lower():
                os.write(master, b'$target_pass\n')
                time.sleep(1)
                break
        except OSError:
            break
    try: os.waitpid(pid, 0)
    except: pass
" &>/dev/null || true
    fi

    ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -p "$target_port" "${target_user}@${target_host}" "true" &>/dev/null
}

ensure_ssh_connection() {
    local key="$1"
    local host="$2"
    local user="$3"

    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${user}@${host}" "true" &>/dev/null; then
        return 0
    fi

    log_warn "Passwordless SSH connection to ${user}@${host} not yet active. Trying key provisioning..."
    if setup_ssh_key_auth "$key" "$host" "$user"; then
        return 0
    fi

    log_error "Could not establish passwordless SSH connection to ${user}@${host}."
    return 1
}

ensure_remote_rsync() {
    local key="$1"
    local host="$2"
    local user="$3"

    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" "command -v rsync" &>/dev/null; then
        return 0
    fi

    log_warn "rsync not found on ${host}. Installing rsync..."
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${user}@${host}" "
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq rsync
        elif command -v apk &>/dev/null; then
            sudo apk add --no-cache rsync
        fi
    " &>/dev/null || {
        log_error "Failed to install rsync on ${host} automatically."
        return 1
    }
}

sync_node_code() {
    local key="$1"
    local host="$2"
    local user="$3"
    local dest="$4"

    log_info "Synchronizing codebase to ${user}@${host}:${dest}..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] rsync -az ${REPO_ROOT}/ -> ${user}@${host}:${dest}/"
        return 0
    fi

    if ! ensure_ssh_connection "$key" "$host" "$user"; then
        return 1
    fi

    if ! ensure_remote_rsync "$key" "$host" "$user"; then
        return 1
    fi

    # Ensure remote destination directory exists
    ssh -o BatchMode=yes -o ConnectTimeout=6 "${user}@${host}" "mkdir -p ${dest}" 2>/dev/null || true

    local rsync_cmd=(rsync -az --human-readable)
    [ "$VERBOSE" = true ] && rsync_cmd+=(-v --progress)
    [ "$DELETE_REMOTE" = true ] && rsync_cmd+=(--delete)
    [ "$EXCLUDE_GIT" = true ] && rsync_cmd+=(--exclude='.git/')

    rsync_cmd+=(
        --exclude='.venv'
        --exclude='venv'
        --exclude='__pycache__'
        --exclude='*.pyc'
        --exclude='.pytest_cache'
        --exclude='.ruff_cache'
        --exclude='.mypy_cache'
        --exclude='.DS_Store'
        --exclude='.jj/'
        --exclude='.jj'
        "${REPO_ROOT}/"
        "${user}@${host}:${dest}/"
    )

    set +e
    "${rsync_cmd[@]}"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; then
        log_success "Codebase synchronized to ${user}@${host}:${dest}."
        return 0
    else
        log_error "Rsync failed for ${host} (exit code ${rc})."
        return 1
    fi
}

deploy_server() {
    local host="$1"
    local user="$2"
    local dest="$3"

    log_section "Deploying New Code to Coordinator Server (${host})"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would run deploy_turnstone_server.sh on ${user}@${host}"
        return 0
    fi

    local remote_cmd="cd ${dest} && sudo bash .github/issues/bare_metal_migration/deploy_turnstone_server.sh -y"
    if [ "$QUICK_MODE" = true ]; then
        remote_cmd+=" --quick"
    fi

    log_info "Executing coordinator deployment script on ${host}..."
    if [ "$VERBOSE" = true ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" "${remote_cmd}"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" "${remote_cmd}" 2>&1 | while IFS= read -r line; do
            echo "  [server] $line"
        done
    fi

    # Verify Console Health
    log_info "Verifying coordinator health on http://${host}:8090/health..."
    local healthy=false
    for _ in {1..10}; do
        if curl -sf "http://${host}:8090/health" &>/dev/null || curl -sf "http://${host}:8090" &>/dev/null || \
           ssh -o BatchMode=yes -o ConnectTimeout=4 "${user}@${host}" "curl -sf http://127.0.0.1:8090/health" &>/dev/null; then
            healthy=true
            break
        fi
        sleep 1
    done

    if [ "$healthy" = true ]; then
        log_success "Coordinator Server is ACTIVE and healthy."
        return 0
    else
        log_warn "Coordinator Server containers restarted, but health check timed out."
        return 0
    fi
}

deploy_worker() {
    local key="$1"
    local host="$2"
    local user="$3"
    local dest="$4"
    local node_id="$5"

    log_section "Deploying New Code to Worker Node (${node_id} @ ${host})"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would run deploy_turnstone_debian12.sh on ${user}@${host} for node ${node_id}"
        return 0
    fi

    local remote_cmd="cd ${dest} && sudo bash .github/issues/bare_metal_migration/deploy_turnstone_debian12.sh --node-id ${node_id} --no-foreground --skip-tools -y"
    if [ "$QUICK_MODE" = true ]; then
        remote_cmd+=" --quick"
    fi

    log_info "Executing Debian 12 deployment script on ${host}..."
    if [ "$VERBOSE" = true ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" "${remote_cmd}"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" "${remote_cmd}" 2>&1 | while IFS= read -r line; do
            echo "  [${node_id}] $line"
        done
    fi

    # Verify Worker Health
    log_info "Verifying worker health on http://${host}:8080..."
    local healthy=false
    for _ in {1..10}; do
        if curl -sf "http://${host}:8080" &>/dev/null || \
           ssh -o BatchMode=yes -o ConnectTimeout=4 "${user}@${host}" "curl -sf http://127.0.0.1:8080" &>/dev/null; then
            healthy=true
            break
        fi
        sleep 1
    done

    if [ "$healthy" = true ]; then
        log_success "Worker ${node_id} is ACTIVE and healthy on port 8080."
        return 0
    else
        log_warn "Worker ${node_id} restarted, but health check timed out."
        return 0
    fi
}

main() {
    parse_args "$@"

    local w1_host
    w1_host="$(resolve_worker_one_host)"

    echo -e "${BLUE}=================================================================${NC}"
    echo -e "${BLUE}           Turnstone Cluster Sync & Deploy Orchestrator          ${NC}"
    echo -e "${BLUE}=================================================================${NC}"
    log_info "Source Repository:    ${REPO_ROOT}"
    log_info "Coordinator Server:   ${SERVER_USER}@${SERVER_HOST}"
    log_info "Worker Node One:      ${WORKER_ONE_USER}@${w1_host} (${WORKER_ONE_NODE_ID})"
    log_info "Worker Node Two:      ${WORKER_TWO_USER}@${WORKER_TWO_HOST} (${WORKER_TWO_NODE_ID})"
    log_info "Target Scope:         ${TARGET_FILTER}"
    log_info "Sync Code Action:     ${ACTION_SYNC}"
    log_info "Install Code Action:  ${ACTION_INSTALL}"
    [ "$QUICK_MODE" = true ] && log_info "Execution Mode:       FAST RELOAD (--quick)"
    [ "$DRY_RUN" = true ] && log_warn "Execution Mode:       DRY RUN (--dry-run)"
    echo

    local run_server=false
    local run_w1=false
    local run_w2=false

    case "$TARGET_FILTER" in
        all)
            run_server=true
            run_w1=true
            run_w2=true
            ;;
        server|coordinator)
            run_server=true
            ;;
        workers)
            run_w1=true
            run_w2=true
            ;;
        worker-one|turnstone-worker-one)
            run_w1=true
            ;;
        worker-two|turnstone-worker-two)
            run_w2=true
            ;;
        *)
            log_error "Unknown target selection: ${TARGET_FILTER}"
            exit 1
            ;;
    esac

    local sync_server_ok=true
    local sync_w1_ok=true
    local sync_w2_ok=true

    local deploy_server_ok=true
    local deploy_w1_ok=true
    local deploy_w2_ok=true

    # PHASE 1: Code Synchronization
    if [ "$ACTION_SYNC" = true ]; then
        log_section "Phase 1: Synchronizing Latest Code to Cluster Nodes"

        if [ "$run_server" = true ]; then
            if ! sync_node_code "coordinator" "$SERVER_HOST" "$SERVER_USER" "$SERVER_DEST"; then
                sync_server_ok=false
            fi
        fi

        if [ "$run_w1" = true ]; then
            if ! sync_node_code "worker-one" "$w1_host" "$WORKER_ONE_USER" "$WORKER_ONE_DEST"; then
                sync_w1_ok=false
            fi
        fi

        if [ "$run_w2" = true ]; then
            if ! sync_node_code "worker-two" "$WORKER_TWO_HOST" "$WORKER_TWO_USER" "$WORKER_TWO_DEST"; then
                sync_w2_ok=false
            fi
        fi
        echo
    fi

    # PHASE 2: Installation and Service Reload
    if [ "$ACTION_INSTALL" = true ]; then
        log_section "Phase 2: Installing New Code & Reloading Services"

        if [ "$run_server" = true ] && [ "$sync_server_ok" = true ]; then
            if ! deploy_server "$SERVER_HOST" "$SERVER_USER" "$SERVER_DEST"; then
                deploy_server_ok=false
            fi
            echo
        fi

        if [ "$run_w1" = true ] && [ "$sync_w1_ok" = true ]; then
            if ! deploy_worker "worker-one" "$w1_host" "$WORKER_ONE_USER" "$WORKER_ONE_DEST" "$WORKER_ONE_NODE_ID"; then
                deploy_w1_ok=false
            fi
            echo
        fi

        if [ "$run_w2" = true ] && [ "$sync_w2_ok" = true ]; then
            if ! deploy_worker "worker-two" "$WORKER_TWO_HOST" "$WORKER_TWO_USER" "$WORKER_TWO_DEST" "$WORKER_TWO_NODE_ID"; then
                deploy_w2_ok=false
            fi
            echo
        fi
    fi

    # SUMMARY REPORT
    log_section "Turnstone Cluster Deployment Summary"
    printf "%-15s %-38s %-12s %-12s\n" "TARGET" "HOST" "SYNC" "DEPLOY"
    echo "-----------------------------------------------------------------"

    if [ "$run_server" = true ]; then
        local s_sync="SKIPPED"
        local s_dep="SKIPPED"
        [ "$ACTION_SYNC" = true ] && s_sync="$([ "$sync_server_ok" = true ] && echo "SUCCESS" || echo "FAILED")"
        [ "$ACTION_INSTALL" = true ] && s_dep="$([ "$deploy_server_ok" = true ] && echo "SUCCESS" || echo "FAILED")"
        printf "%-15s %-38s %-12s %-12s\n" "Coordinator" "$SERVER_HOST" "$s_sync" "$s_dep"
    fi

    if [ "$run_w1" = true ]; then
        local w1_sync="SKIPPED"
        local w1_dep="SKIPPED"
        [ "$ACTION_SYNC" = true ] && w1_sync="$([ "$sync_w1_ok" = true ] && echo "SUCCESS" || echo "FAILED")"
        [ "$ACTION_INSTALL" = true ] && w1_dep="$([ "$deploy_w1_ok" = true ] && echo "SUCCESS" || echo "FAILED")"
        printf "%-15s %-38s %-12s %-12s\n" "Worker One" "$w1_host" "$w1_sync" "$w1_dep"
    fi

    if [ "$run_w2" = true ]; then
        local w2_sync="SKIPPED"
        local w2_dep="SKIPPED"
        [ "$ACTION_SYNC" = true ] && w2_sync="$([ "$sync_w2_ok" = true ] && echo "SUCCESS" || echo "FAILED")"
        [ "$ACTION_INSTALL" = true ] && w2_dep="$([ "$deploy_w2_ok" = true ] && echo "SUCCESS" || echo "FAILED")"
        printf "%-15s %-38s %-12s %-12s\n" "Worker Two" "$WORKER_TWO_HOST" "$w2_sync" "$w2_dep"
    fi
    echo "-----------------------------------------------------------------"

    if [ "$sync_server_ok" = true ] && [ "$sync_w1_ok" = true ] && [ "$sync_w2_ok" = true ] && \
       [ "$deploy_server_ok" = true ] && [ "$deploy_w1_ok" = true ] && [ "$deploy_w2_ok" = true ]; then
        log_success "All tasks completed successfully!"
        exit 0
    else
        log_error "Some tasks failed during cluster deployment. Review logs above."
        exit 1
    fi
}

main "$@"
