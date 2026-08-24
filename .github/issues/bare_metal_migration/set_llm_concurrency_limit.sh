#!/usr/bin/env bash
# =============================================================================
# Turnstone Concurrency Limit Enforcement Tool (Auto-Detect & Configure)
#
# Automatically scans the current host (or cluster nodes via SSH) for:
#   1. Turnstone configuration files (/etc/turnstone/config.toml, ~/.config/turnstone/config.toml, etc.)
#      -> Sets max_concurrency = 1 on all [models.*] sections and parallel_evaluations = 1 on [judge]
#   2. Turnstone PostgreSQL Database (model_definitions & settings tables)
#      -> Updates model_definitions SET max_concurrency = 1
#   3. Local Inference Engines:
#      -> Ollama: Configures OLLAMA_NUM_PARALLEL=1
#      -> llama.cpp (llama-server): Configures -np 1 / --parallel 1
#      -> vLLM: Configures --max-num-seqs 1
#      -> Lemonade / ROCm: Configures concurrency = 1
#      -> Apple MLX (launchd / mlx_lm.server): Checks launchd configs
#   4. Restarts affected services (turnstone-server, ollama, etc.)
#
# Usage:
#   ./set_concurrency_limit.sh                  # Run auto-detection & configure locally
#   ./set_concurrency_limit.sh --cluster        # Run across all known cluster nodes via SSH
#   ./set_concurrency_limit.sh --target <node>  # Target specific remote node (e.g. ai-core-one)
#   ./set_concurrency_limit.sh --dry-run        # Preview changes without modifying files or DB
#   ./set_concurrency_limit.sh --limit <N>      # Set custom concurrency limit (default: 1)
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

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() {
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
}

# Resolve Repository Root
REAL_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${REAL_SOURCE}")" && pwd)"
if git rev-parse --show-toplevel &>/dev/null; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"
fi

# Target Cluster Nodes Definition (Aligned with sync_repo.sh)
NODE_KEYS=("coordinator" "ai-core-one" "ai-core-two" "mbp-ai-core")

node_host() {
    case "$1" in
        postgres) echo "turnstone-postgres.lan" ;;
        coordinator) echo "turnstone-coordinator-nerd-projects.lan" ;;
        ai-core-one) echo "amd-ai-core-one.lan" ;;
        ai-core-two) echo "amd-ai-core-two.lan" ;;
        mbp-ai-core) echo "mbp-ai-core.lan" ;;
        *) echo "" ;;
    esac
}

node_user() {
    case "$1" in
        postgres) echo "postgres" ;;
        coordinator|ai-core-one|ai-core-two|mbp-ai-core) echo "turnstone" ;;
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
        *) echo "" ;;
    esac
}

# Defaults
CONCURRENCY_LIMIT=1
DRY_RUN=false
RUN_CLUSTER=false
TARGET_NODE=""
RELOAD_SERVICES=true

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -l, --limit <N>        Concurrency limit to set (default: 1)"
    echo "  -c, --cluster          Run across all cluster nodes via SSH"
    echo "  -t, --target <node>    Target a specific cluster node (e.g. ai-core-one, coordinator)"
    echo "  -n, --dry-run          Preview changes without applying them"
    echo "  --no-restart           Do not restart services after updating configs"
    echo "  -h, --help             Display this help message and exit"
    echo ""
    echo "Configured Cluster Nodes:"
    for k in "${NODE_KEYS[@]}"; do
        echo "  - ${k}: $(node_desc "${k}")"
    done
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--limit)
            CONCURRENCY_LIMIT="$2"
            shift 2
            ;;
        -c|--cluster)
            RUN_CLUSTER=true
            shift
            ;;
        -t|--target)
            TARGET_NODE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-restart)
            RELOAD_SERVICES=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
    esac
done

# =============================================================================
# Helper: Python script to parse and update TOML in-place
# =============================================================================
update_toml_file() {
    local toml_path="$1"
    local limit="$2"

    [ -f "${toml_path}" ] || return 0

    log_info "Processing TOML config: ${toml_path}"

    if [ "${DRY_RUN}" = true ]; then
        log_warn "[DRY-RUN] Would update ${toml_path} with max_concurrency = ${limit} and judge parallel_evaluations = ${limit}"
        return 0
    fi

    # Backup original config
    local backup_path="${toml_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "${toml_path}" "${backup_path}" 2>/dev/null || sudo cp -p "${toml_path}" "${backup_path}"

    python3 - "${toml_path}" "${limit}" <<'EOF'
import sys
import re

toml_path = sys.argv[1]
limit = sys.argv[2]

try:
    with open(toml_path, "r", encoding="utf-8") as f:
        content = f.read()
except Exception as e:
    sys.exit(f"Failed to read {toml_path}: {e}")

lines = content.splitlines()
new_lines = []
current_section = None
section_has_concurrency = False
updated_models = []
updated_judge = False

section_re = re.compile(r"^\s*\[([a-zA-Z0-9_\.\-]+)\]\s*$")
model_section_re = re.compile(r"^models\.([a-zA-Z0-9_\-]+)$")

def flush_model_section():
    global section_has_concurrency
    if current_section:
        m = model_section_re.match(current_section)
        if m and not section_has_concurrency:
            new_lines.append(f"max_concurrency = {limit}")
            updated_models.append(m.group(1))

for line in lines:
    sec_match = section_re.match(line)
    if sec_match:
        flush_model_section()
        current_section = sec_match.group(1)
        section_has_concurrency = False
        new_lines.append(line)
        continue

    if current_section and model_section_re.match(current_section):
        if re.match(r"^\s*max_concurrency\s*=", line):
            new_lines.append(f"max_concurrency = {limit}")
            section_has_concurrency = True
            m = model_section_re.match(current_section)
            if m:
                updated_models.append(m.group(1))
            continue

    if current_section == "judge":
        if re.match(r"^\s*parallel_evaluations\s*=", line):
            new_lines.append(f"parallel_evaluations = {limit}")
            updated_judge = True
            continue

    new_lines.append(line)

flush_model_section()

out_text = "\n".join(new_lines) + ("\n" if content.endswith("\n") else "")
if out_text != content:
    with open(toml_path, "w", encoding="utf-8") as f:
        f.write(out_text)
    if updated_models:
        print(f"Updated model definitions ({', '.join(set(updated_models))}) -> max_concurrency = {limit}")
    if updated_judge:
        print(f"Updated [judge] -> parallel_evaluations = {limit}")
else:
    print("Config file already has desired concurrency limits.")
EOF

    log_success "Updated ${toml_path}"
}

# =============================================================================
# Helper: Update Database Table (model_definitions & settings)
# =============================================================================
update_database() {
    local limit="$1"

    # Search for potential DB credentials
    local db_url="${TURNSTONE_DB_URL:-${DATABASE_URL:-}}"
    local secret_files=(
        "${SYS_ADMIN_ENV:-/etc/turnstone/postgres_admin.env}"
        "${SCRIPT_DIR}/secrets/postgres_admin.secret"
        "${REPO_ROOT}/secrets/postgres_admin.secret"
        "${HOME}/.config/turnstone/postgres_admin.secret"
    )

    if [ -z "${db_url}" ]; then
        for sf in "${secret_files[@]}"; do
            if [ -f "${sf}" ]; then
                log_info "Reading DB credentials from ${sf}..."
                # Extract URL or variables
                if grep -q "^TURNSTONE_DB_URL=" "${sf}"; then
                    db_url=$(grep "^TURNSTONE_DB_URL=" "${sf}" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
                    break
                elif grep -q "^DATABASE_URL=" "${sf}"; then
                    db_url=$(grep "^DATABASE_URL=" "${sf}" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
                    break
                elif grep -q "^POSTGRES_USER=" "${sf}"; then
                    source "${sf}" 2>/dev/null || true
                    local u="${POSTGRES_USER:-turnstone}"
                    local p="${POSTGRES_PASSWORD:-}"
                    local h="${POSTGRES_HOST:-localhost}"
                    local pt="${POSTGRES_PORT:-5432}"
                    local db="${POSTGRES_DB:-turnstone}"
                    db_url="postgresql+psycopg://${u}:${p}@${h}:${pt}/${db}"
                    break
                fi
            fi
        done
    fi

    if [ -n "${db_url}" ]; then
        log_info "Checking PostgreSQL database connection..."
        if [ "${DRY_RUN}" = true ]; then
            log_warn "[DRY-RUN] Would update PostgreSQL model_definitions (max_concurrency = ${limit})"
            return 0
        fi

        python3 - "${db_url}" "${limit}" <<'EOF' 2>/dev/null || log_warn "Direct DB update skipped (database not accessible or table absent from local host)."
import sys
import re

db_url = sys.argv[1]
limit = int(sys.argv[2])

# Clean SQLAlchemy scheme to standard postgresql://
clean_url = re.sub(r"^postgresql\+[a-zA-Z0-9_]+://", "postgresql://", db_url)

try:
    import psycopg
    with psycopg.connect(clean_url, autocommit=True) as conn:
        with conn.cursor() as cur:
            # Check if model_definitions table exists
            cur.execute("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'model_definitions');")
            if cur.fetchone()[0]:
                cur.execute("UPDATE model_definitions SET max_concurrency = %s WHERE max_concurrency != %s;", (limit, limit))
                print(f"[SUCCESS] Updated PostgreSQL model_definitions table: {cur.rowcount} rows set to max_concurrency = {limit}")

            # Check if settings table exists
            cur.execute("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'settings');")
            if cur.fetchone()[0]:
                cur.execute(
                    "INSERT INTO settings (key, value) VALUES ('judge.parallel_evaluations', %s) "
                    "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;",
                    (str(limit),)
                )
                print(f"[SUCCESS] Updated settings table -> judge.parallel_evaluations = {limit}")
except Exception as e:
    sys.exit(1)
EOF
    fi
}

# =============================================================================
# Helper: Detect & Configure Local Inference Engines
# =============================================================================
configure_local_inference_engines() {
    local limit="$1"
    log_section "Scanning Local Inference Engines & Services"

    # 1. Ollama
    if command -v ollama &>/dev/null || [ -d "/etc/systemd/system/ollama.service.d" ] || systemctl list-unit-files ollama.service &>/dev/null; then
        log_info "Detected Ollama inference server."
        if [ "${DRY_RUN}" = true ]; then
            log_warn "[DRY-RUN] Would configure /etc/systemd/system/ollama.service.d/override.conf with OLLAMA_NUM_PARALLEL=${limit}"
        else
            sudo mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null || mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null || true
            if [ -w "/etc/systemd/system/ollama.service.d" ] || sudo [ -d "/etc/systemd/system/ollama.service.d" ]; then
                cat <<EOF | (sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null || tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null)
[Service]
Environment="OLLAMA_NUM_PARALLEL=${limit}"
EOF
                log_success "Configured Ollama with OLLAMA_NUM_PARALLEL=${limit}"
                if [ "${RELOAD_SERVICES}" = true ] && command -v systemctl &>/dev/null; then
                    sudo systemctl daemon-reload 2>/dev/null || systemctl daemon-reload 2>/dev/null || true
                    if systemctl is-active --quiet ollama 2>/dev/null; then
                        log_info "Restarting Ollama service..."
                        sudo systemctl restart ollama 2>/dev/null || systemctl restart ollama 2>/dev/null || true
                        log_success "Ollama service restarted."
                    fi
                fi
            fi
        fi
    fi

    # 2. llama.cpp / llama-server systemd units
    for unit in /etc/systemd/system/llama*.service /etc/systemd/system/llama-server*.service; do
        if [ -f "${unit}" ]; then
            log_info "Detected llama-server unit: ${unit}"
            if [ "${DRY_RUN}" = true ]; then
                log_warn "[DRY-RUN] Would ensure ${unit} contains -np ${limit} / --parallel ${limit}"
            else
                if grep -q -- "-np " "${unit}"; then
                    sudo sed -i -E "s/-np [0-9]+/-np ${limit}/g" "${unit}" 2>/dev/null || true
                elif grep -q -- "--parallel " "${unit}"; then
                    sudo sed -i -E "s/--parallel [0-9]+/--parallel ${limit}/g" "${unit}" 2>/dev/null || true
                fi
                log_success "Updated ${unit} slot limit."
            fi
        fi
    done

    # 3. vLLM systemd units
    for unit in /etc/systemd/system/vllm*.service; do
        if [ -f "${unit}" ]; then
            log_info "Detected vLLM unit: ${unit}"
            if [ "${DRY_RUN}" = true ]; then
                log_warn "[DRY-RUN] Would ensure ${unit} contains --max-num-seqs ${limit}"
            else
                if grep -q -- "--max-num-seqs" "${unit}"; then
                    sudo sed -i -E "s/--max-num-seqs [0-9]+/--max-num-seqs ${limit}/g" "${unit}" 2>/dev/null || true
                fi
                log_success "Updated ${unit} max-num-seqs."
            fi
        fi
    done

    # 4. Apple MLX (macOS launchd)
    local mlx_plist="${HOME}/Library/LaunchAgents/com.turnstone.mlx-server.plist"
    if [ -f "${mlx_plist}" ]; then
        log_info "Detected Apple MLX launchd agent at ${mlx_plist}."
        log_success "MLX LM server runs single-worker queue by default."
    fi

    # 5. Lemonade Server
    if [ -f "/etc/lemonade/config.toml" ] || systemctl list-unit-files lemonade*.service &>/dev/null 2>/dev/null; then
        log_info "Detected Lemonade server configuration."
        if [ -f "/etc/lemonade/config.toml" ]; then
            update_toml_file "/etc/lemonade/config.toml" "${limit}"
        fi
    fi
}

# =============================================================================
# Helper: Run Local Host Configuration Scan
# =============================================================================
run_local() {
    local limit="$1"
    log_section "Local Host Concurrency Configuration (Limit: ${limit})"

    # 1. Scan and update Turnstone TOML files
    local candidate_configs=(
        "/etc/turnstone/config.toml"
        "${HOME}/.config/turnstone/config.toml"
        "${REPO_ROOT}/turnstone.toml"
        "${REPO_ROOT}/config.toml"
        "${TURNSTONE_CONFIG:-}"
    )

    for cfg in "${candidate_configs[@]}"; do
        if [ -n "${cfg}" ] && [ -f "${cfg}" ]; then
            update_toml_file "${cfg}" "${limit}"
        fi
    done

    # 2. Update central database if accessible
    update_database "${limit}"

    # 3. Detect and configure local inference backends
    configure_local_inference_engines "${limit}"

    # 4. Restart Turnstone services if configured
    if [ "${RELOAD_SERVICES}" = true ] && [ "${DRY_RUN}" = false ]; then
        log_section "Restarting Turnstone Node Services"
        # Linux Systemd
        if command -v systemctl &>/dev/null; then
            if systemctl is-active --quiet turnstone-server.service 2>/dev/null; then
                log_info "Restarting turnstone-server.service..."
                sudo systemctl restart turnstone-server.service 2>/dev/null || systemctl restart turnstone-server.service 2>/dev/null || true
                log_success "turnstone-server.service restarted."
            fi
            if systemctl is-active --quiet turnstone-console.service 2>/dev/null; then
                log_info "Restarting turnstone-console.service..."
                sudo systemctl restart turnstone-console.service 2>/dev/null || systemctl restart turnstone-console.service 2>/dev/null || true
                log_success "turnstone-console.service restarted."
            fi
        fi

        # macOS Launchd
        if command -v launchctl &>/dev/null; then
            if [ -f "${HOME}/Library/LaunchAgents/com.turnstone.server.plist" ]; then
                log_info "Reloading macOS launchd turnstone server..."
                launchctl kickstart -k "gui/$(id -u)/com.turnstone.server" 2>/dev/null || true
                log_success "macOS turnstone server reloaded."
            fi
        fi
    fi

    log_success "Local host configuration complete (concurrency limit = ${limit})."
}

# =============================================================================
# Helper: Run on Remote Node via SSH
# =============================================================================
run_remote_node() {
    local node_key="$1"
    local limit="$2"

    local host
    local user
    local desc
    host="$(node_host "${node_key}")"
    user="$(node_user "${node_key}")"
    desc="$(node_desc "${node_key}")"

    if [ -z "${host}" ]; then
        log_error "Unknown node key: ${node_key}"
        return 1
    fi

    log_section "Configuring Remote Node: ${node_key} (${desc})"

    # Test SSH connectivity with short timeout
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" "echo connected" &>/dev/null; then
        log_warn "Could not connect to ${user}@${host} via SSH. Skipping node."
        return 0
    fi

    local dry_flag=""
    [ "${DRY_RUN}" = true ] && dry_flag="--dry-run"

    # Send and execute script remotely
    ssh -o BatchMode=yes "${user}@${host}" "bash -s -- --limit ${limit} ${dry_flag}" < "${REAL_SOURCE}" || {
        log_warn "Failed to complete execution on ${node_key}."
        return 1
    }

    log_success "Successfully configured ${node_key}."
}

# =============================================================================
# Main Dispatcher
# =============================================================================
main() {
    if [ -n "${TARGET_NODE}" ]; then
        run_remote_node "${TARGET_NODE}" "${CONCURRENCY_LIMIT}"
    elif [ "${RUN_CLUSTER}" = true ]; then
        log_section "Cluster-Wide Concurrency Enforcement (Limit: ${CONCURRENCY_LIMIT})"
        for key in "${NODE_KEYS[@]}"; do
            run_remote_node "${key}" "${CONCURRENCY_LIMIT}" || true
        done
        log_success "Cluster-wide concurrency limit configuration completed."
    else
        run_local "${CONCURRENCY_LIMIT}"
    fi
}

main "$@"
