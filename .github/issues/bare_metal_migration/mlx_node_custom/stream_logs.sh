#!/usr/bin/env bash
# ==============================================================================
# Turnstone MLX & Ollama Node Log Streamer
# Streams real-time logs for Dynamic MLX Server, Ollama Server, and Turnstone.
# Supports macOS Unified Logging System (log stream) and log file tailing.
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
MAGENTA="\033[0;35m"
NC="\033[0m"

# Default Paths
CURRENT_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="${HOME:-/Users/${CURRENT_USER}}"
LOG_DIR="${USER_HOME}/Library/Logs"

# Default Modes and Filters
MODE="stream"       # "stream" (macOS log stream) or "tail" (file follow)
TARGET="all"        # "all", "mlx", "ollama", "server"
LOG_LEVEL="info"    # "info", "debug", "error"

print_usage() {
    cat <<EOF
${BOLD}Turnstone MLX Node Real-Time Log Streamer${NC}

Usage: $(basename "$0") [OPTIONS]

Modes:
  -s, --stream         Stream logs using macOS Unified Logging (log stream) [Default on macOS]
  -t, --tail           Follow local log files in ${LOG_DIR}/ (*.log, *.err)
  -a, --all            Show logs for all services (MLX, Ollama, Turnstone) [Default]

Service Filters:
  --mlx                Stream only Dynamic MLX Server logs
  --ollama             Stream only Ollama Server logs
  --server             Stream only Turnstone Server logs

Options:
  --debug              Include debug level logs in stream
  --info               Include info level logs in stream (default)
  --error              Include error level logs in stream only
  -h, --help           Show this help message and exit

Examples:
  $(basename "$0")                         # Stream all node logs in real-time
  $(basename "$0") --mlx                   # Stream only Dynamic MLX Server logs
  $(basename "$0") --ollama                # Stream only Ollama activity
  $(basename "$0") --tail                  # Tail raw log files on disk
EOF
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--stream)
            MODE="stream"
            shift
            ;;
        -t|--tail)
            MODE="tail"
            shift
            ;;
        -a|--all)
            TARGET="all"
            shift
            ;;
        --mlx)
            TARGET="mlx"
            shift
            ;;
        --ollama)
            TARGET="ollama"
            shift
            ;;
        --server)
            TARGET="server"
            shift
            ;;
        --debug)
            LOG_LEVEL="debug"
            shift
            ;;
        --info)
            LOG_LEVEL="info"
            shift
            ;;
        --error)
            LOG_LEVEL="error"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Check if log stream is available (macOS)
if [ "${MODE}" = "stream" ] && ! command -v log &>/dev/null; then
    echo -e "${YELLOW}[WARNING] macOS 'log' command not found. Falling back to log file tail mode.${NC}"
    MODE="tail"
fi

if [ "${MODE}" = "stream" ]; then
    echo -e "${GREEN}${BOLD}=== Starting macOS Unified Log Stream ===${NC}"
    echo -e "${CYAN}Target Filter:${NC} ${TARGET} | ${CYAN}Log Level:${NC} ${LOG_LEVEL}"
    echo -e "${YELLOW}Press Ctrl+C to stop streaming.${NC}\n"

    # Build Predicate
    PREDICATE=""
    case "${TARGET}" in
        mlx)
            PREDICATE='(process == "python" OR process == "python3" OR sender CONTAINS "dynamic_mlx_server" OR eventMessage CONTAINS[c] "DynamicMLXServer" OR eventMessage CONTAINS[c] "mlx")'
            ;;
        ollama)
            PREDICATE='(process == "ollama" OR sender CONTAINS "ollama" OR eventMessage CONTAINS[c] "ollama")'
            ;;
        server)
            PREDICATE='(process == "turnstone-server" OR eventMessage CONTAINS[c] "turnstone")'
            ;;
        all|*)
            PREDICATE='(process == "ollama" OR process == "python" OR process == "python3" OR process == "turnstone-server" OR sender CONTAINS "dynamic_mlx_server" OR eventMessage CONTAINS[c] "DynamicMLXServer" OR eventMessage CONTAINS[c] "mlx" OR eventMessage CONTAINS[c] "ollama" OR eventMessage CONTAINS[c] "turnstone")'
            ;;
    esac

    LOG_LEVEL_ARGS=("--info")
    if [ "${LOG_LEVEL}" = "debug" ]; then
        LOG_LEVEL_ARGS=("--info" "--debug")
    fi

    # Execute log stream
    exec log stream --predicate "${PREDICATE}" "${LOG_LEVEL_ARGS[@]}" --style compact

elif [ "${MODE}" = "tail" ]; then
    echo -e "${GREEN}${BOLD}=== Tailing Turnstone Log Files (${LOG_DIR}) ===${NC}"
    echo -e "${CYAN}Target Filter:${NC} ${TARGET}"
    echo -e "${YELLOW}Press Ctrl+C to stop streaming.${NC}\n"

    FILES_TO_TAIL=()
    case "${TARGET}" in
        mlx)
            [ -f "${LOG_DIR}/mlx-server.log" ] && FILES_TO_TAIL+=("${LOG_DIR}/mlx-server.log")
            [ -f "${LOG_DIR}/mlx-server.err" ] && FILES_TO_TAIL+=("${LOG_DIR}/mlx-server.err")
            ;;
        ollama)
            [ -f "${LOG_DIR}/ollama.log" ] && FILES_TO_TAIL+=("${LOG_DIR}/ollama.log")
            [ -f "${LOG_DIR}/ollama.err" ] && FILES_TO_TAIL+=("${LOG_DIR}/ollama.err")
            ;;
        server)
            [ -f "${LOG_DIR}/turnstone-server.log" ] && FILES_TO_TAIL+=("${LOG_DIR}/turnstone-server.log")
            [ -f "${LOG_DIR}/turnstone-server.err" ] && FILES_TO_TAIL+=("${LOG_DIR}/turnstone-server.err")
            ;;
        all|*)
            for f in "${LOG_DIR}/mlx-server.log" "${LOG_DIR}/mlx-server.err" \
                     "${LOG_DIR}/ollama.log" "${LOG_DIR}/ollama.err" \
                     "${LOG_DIR}/turnstone-server.log" "${LOG_DIR}/turnstone-server.err"; do
                [ -f "$f" ] && FILES_TO_TAIL+=("$f")
            done
            ;;
    esac

    if [ ${#FILES_TO_TAIL[@]} -eq 0 ]; then
        echo -e "${YELLOW}No log files found in ${LOG_DIR} for target '${TARGET}'.${NC}"
        echo -e "Waiting for files to be created..."
        mkdir -p "${LOG_DIR}"
        touch "${LOG_DIR}/mlx-server.log" "${LOG_DIR}/ollama.log" "${LOG_DIR}/turnstone-server.log"
        FILES_TO_TAIL=("${LOG_DIR}/mlx-server.log" "${LOG_DIR}/ollama.log" "${LOG_DIR}/turnstone-server.log")
    fi

    exec tail -f -n 50 "${FILES_TO_TAIL[@]}"
fi
