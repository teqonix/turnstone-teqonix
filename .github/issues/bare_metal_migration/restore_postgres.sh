#!/usr/bin/env bash
# =============================================================================
# Turnstone PostgreSQL Database Restore Script
#
# Idempotent script to restore a Turnstone database backup (.sql, .sql.gz, or .dump)
# into an existing PostgreSQL database instance.
# Credentials can be loaded from secrets/postgres_admin.secret by default or overridden
# via environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE) and CLI flags.
# =============================================================================

set -euo pipefail

# Color Codes for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "An error occurred on line $LINENO. Database restore stopped."; exit 1' ERR

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)"

# Default secret file locations
DEFAULT_SECRET_FILE="${REPO_ROOT}/secrets/postgres_admin.secret"
SYS_ADMIN_ENV="/etc/turnstone/postgres_admin.env"

SECRET_FILE="${POSTGRES_ADMIN_SECRET_FILE:-}"
IMPORT_BACKUP_FILE="${IMPORT_BACKUP_FILE:-}"
TARGET_DB="${TARGET_DB:-${PGDATABASE:-}}"
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-}"
PGUSER="${PGUSER:-}"
PGPASSWORD="${PGPASSWORD:-}"

# Parse command-line parameters
usage() {
    echo "Usage: $0 [OPTIONS] [<path_to_backup_file>]"
    echo ""
    echo "Options:"
    echo "  -f, --file <path>        Path to database backup file (.sql, .sql.gz, .dump, .tar)"
    echo "  -d, --dbname <name>      Target database name (default: turnstone or from connection URI)"
    echo "  -H, --host <host>        PostgreSQL server host"
    echo "  -p, --port <port>        PostgreSQL server port (default: 5432)"
    echo "  -U, --user <username>    PostgreSQL admin/db user"
    echo "  -W, --password <pass>    PostgreSQL password"
    echo "  -s, --secret-file <path> Path to secret file containing connection URI or env vars"
    echo "  -h, --help               Display this help message and exit"
    echo ""
    echo "Environment Variables Sourced/Respected:"
    echo "  PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE / TARGET_DB,"
    echo "  POSTGRES_ADMIN_SECRET_FILE, TURNSTONE_DB_URL"
    exit 0
}

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            IMPORT_BACKUP_FILE="$2"
            shift 2
            ;;
        -d|--dbname)
            TARGET_DB="$2"
            shift 2
            ;;
        -H|--host)
            PGHOST="$2"
            shift 2
            ;;
        -p|--port)
            PGPORT="$2"
            shift 2
            ;;
        -U|--user)
            PGUSER="$2"
            shift 2
            ;;
        -W|--password)
            PGPASSWORD="$2"
            shift 2
            ;;
        -s|--secret-file)
            SECRET_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ] && [ -z "${IMPORT_BACKUP_FILE}" ]; then
    IMPORT_BACKUP_FILE="${POSITIONAL_ARGS[0]}"
fi

parse_connection_uri() {
    local raw_url="$1"
    raw_url=$(echo "${raw_url}" | tr -d '\r' | xargs)
    local url="${raw_url#*://}"
    
    if [[ "${url}" == *"@"* ]]; then
        local userpass="${url%%@*}"
        local hostportdb="${url#*@}"
        
        if [ -z "${PGUSER:-}" ]; then
            local u="${userpass%%:*}"
            [ -n "${u}" ] && PGUSER="${u}"
        fi
        if [ -z "${PGPASSWORD:-}" ] && [[ "${userpass}" == *":"* ]]; then
            local p="${userpass#*:}"
            [ -n "${p}" ] && PGPASSWORD="${p}"
        fi
        
        local hostport="${hostportdb%%/*}"
        if [[ "${hostportdb}" == *"/"* ]]; then
            local db_in_url="${hostportdb#*/}"
            db_in_url="${db_in_url%%[?#]*}"
            if [ -n "${db_in_url}" ] && [ -z "${TARGET_DB:-}" ]; then
                TARGET_DB="${db_in_url}"
            fi
        fi
        
        if [ -z "${PGHOST:-}" ]; then
            local h="${hostport%%:*}"
            [ -n "${h}" ] && PGHOST="${h}"
        fi
        if [ -z "${PGPORT:-}" ] && [[ "${hostport}" == *":"* ]]; then
            local pt="${hostport#*:}"
            [ -n "${pt}" ] && PGPORT="${pt}"
        fi
    fi
}

load_secrets() {
    local target_file=""

    if [ -n "${SECRET_FILE}" ] && [ -f "${SECRET_FILE}" ]; then
        target_file="${SECRET_FILE}"
    elif [ -f "${DEFAULT_SECRET_FILE}" ]; then
        target_file="${DEFAULT_SECRET_FILE}"
    elif [ -f "${SYS_ADMIN_ENV}" ]; then
        target_file="${SYS_ADMIN_ENV}"
    fi

    if [ -n "${target_file}" ]; then
        log_info "Sourcing database connection credentials from '${target_file}'..."
        
        local first_line
        first_line=$(grep -v '^[[:space:]]*#' "${target_file}" | grep -v '^[[:space:]]*$' | tr -d '\r' | head -n 1 || true)
        
        if [[ "${first_line}" == *"://"* ]] || [[ "${first_line}" == *"@"* ]]; then
            parse_connection_uri "${first_line}"
        elif [[ "${first_line}" == *"="* ]]; then
            local cli_user="${PGUSER}"
            local cli_pass="${PGPASSWORD}"
            local cli_host="${PGHOST}"
            local cli_port="${PGPORT}"
            local cli_db="${TARGET_DB}"

            set +e
            source "${target_file}"
            set -e

            PGUSER="${cli_user:-${PGUSER:-${POSTGRES_ADMIN_USER:-${POSTGRES_USER:-}}}}"
            PGPASSWORD="${cli_pass:-${PGPASSWORD:-${POSTGRES_ADMIN_PASS:-${POSTGRES_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-${POSTGRES_PASS:-}}}}}}"
            PGHOST="${cli_host:-${PGHOST:-${POSTGRES_HOST:-}}}"
            PGPORT="${cli_port:-${PGPORT:-${POSTGRES_PORT:-}}}"
            TARGET_DB="${cli_db:-${TARGET_DB:-${POSTGRES_DB:-${POSTGRES_DATABASE:-}}}}"

            if [ -n "${TURNSTONE_DB_URL:-}" ]; then
                parse_connection_uri "${TURNSTONE_DB_URL}"
            elif [ -n "${DATABASE_URL:-}" ]; then
                parse_connection_uri "${DATABASE_URL}"
            fi
        fi
    fi
}

load_secrets

if [ -n "${TURNSTONE_DB_URL:-}" ]; then
    parse_connection_uri "${TURNSTONE_DB_URL}"
fi

TARGET_DB="${TARGET_DB:-turnstone}"
PGPORT="${PGPORT:-5432}"

if [ -z "${IMPORT_BACKUP_FILE}" ]; then
    echo ""
    read -r -p "Enter full path to backup file (.sql, .sql.gz, .dump, or .tar): " IMPORT_BACKUP_FILE
fi

if [ -z "${IMPORT_BACKUP_FILE}" ]; then
    log_error "No backup file specified. Exiting."
    exit 1
fi

if [ ! -f "${IMPORT_BACKUP_FILE}" ]; then
    log_error "Backup file '${IMPORT_BACKUP_FILE}' not found!"
    exit 1
fi

if ! command -v psql &> /dev/null; then
    log_error "'psql' command not found. Please install postgresql-client."
    exit 1
fi

export PGPORT TARGET_DB
[ -n "${PGUSER}" ] && export PGUSER
[ -n "${PGPASSWORD}" ] && export PGPASSWORD
[ -n "${PGHOST}" ] && export PGHOST

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}       Turnstone PostgreSQL Backup Restore                       ${NC}"
echo -e "${BLUE}=================================================================${NC}"
log_info "Target Host: ${PGHOST:-localhost}:${PGPORT}"
log_info "Target Database: ${TARGET_DB}"
log_info "Database User: ${PGUSER:-<default/local>}"
log_info "Backup File: ${IMPORT_BACKUP_FILE}"

run_psql() {
    local db_name="$1"
    local sql_cmd="$2"

    if [ -n "${PGHOST:-}" ] || [ -n "${PGUSER:-}" ]; then
        psql -d "${db_name}" -c "${sql_cmd}"
    elif [ "$EUID" -eq 0 ]; then
        sudo -u postgres psql -d "${db_name}" -c "${sql_cmd}"
    else
        psql -d "${db_name}" -c "${sql_cmd}"
    fi
}

run_psql_query() {
    local db_name="$1"
    local sql_cmd="$2"

    if [ -n "${PGHOST:-}" ] || [ -n "${PGUSER:-}" ]; then
        psql -d "${db_name}" -tAc "${sql_cmd}"
    elif [ "$EUID" -eq 0 ]; then
        sudo -u postgres psql -d "${db_name}" -tAc "${sql_cmd}"
    else
        psql -d "${db_name}" -tAc "${sql_cmd}"
    fi
}

log_info "Checking if target database '${TARGET_DB}' exists..."
DB_EXISTS=$(run_psql_query "postgres" "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" 2>/dev/null || echo "0")

if [ "${DB_EXISTS}" != "1" ]; then
    log_info "Database '${TARGET_DB}' does not exist. Creating..."
    run_psql "postgres" "CREATE DATABASE ${TARGET_DB};"
    log_success "Database '${TARGET_DB}' created."
else
    log_info "Database '${TARGET_DB}' already exists."
fi

log_info "Importing database dump from '${IMPORT_BACKUP_FILE}'..."

if [[ "${IMPORT_BACKUP_FILE}" == *.sql.gz ]]; then
    log_info "Restoring compressed SQL dump (.sql.gz)..."
    if [ -n "${PGHOST:-}" ] || [ -n "${PGUSER:-}" ]; then
        gunzip -c "${IMPORT_BACKUP_FILE}" | psql -d "${TARGET_DB}" > /dev/null
    elif [ "$EUID" -eq 0 ]; then
        gunzip -c "${IMPORT_BACKUP_FILE}" | sudo -u postgres psql -d "${TARGET_DB}" > /dev/null
    else
        gunzip -c "${IMPORT_BACKUP_FILE}" | psql -d "${TARGET_DB}" > /dev/null
    fi
elif [[ "${IMPORT_BACKUP_FILE}" == *.dump ]] || [[ "${IMPORT_BACKUP_FILE}" == *.tar ]]; then
    log_info "Restoring custom pg_dump archive format..."
    if ! command -v pg_restore &> /dev/null; then
        log_error "'pg_restore' command not found. Please install postgresql-client."
        exit 1
    fi
    if [ -n "${PGHOST:-}" ] || [ -n "${PGUSER:-}" ]; then
        pg_restore -d "${TARGET_DB}" --clean --if-exists "${IMPORT_BACKUP_FILE}" || true
    elif [ "$EUID" -eq 0 ]; then
        sudo -u postgres pg_restore -d "${TARGET_DB}" --clean --if-exists "${IMPORT_BACKUP_FILE}" || true
    else
        pg_restore -d "${TARGET_DB}" --clean --if-exists "${IMPORT_BACKUP_FILE}" || true
    fi
else
    log_info "Restoring plain SQL dump (.sql)..."
    if [ -n "${PGHOST:-}" ] || [ -n "${PGUSER:-}" ]; then
        psql -d "${TARGET_DB}" < "${IMPORT_BACKUP_FILE}" > /dev/null
    elif [ "$EUID" -eq 0 ]; then
        sudo -u postgres psql -d "${TARGET_DB}" < "${IMPORT_BACKUP_FILE}" > /dev/null
    else
        psql -d "${TARGET_DB}" < "${IMPORT_BACKUP_FILE}" > /dev/null
    fi
fi

log_success "Database backup successfully imported into database '${TARGET_DB}'!"

TARGET_APP_USER="${APP_USER:-${PGUSER:-turnstone}}"
if [ "${TARGET_APP_USER}" != "postgres" ]; then
    log_info "Ensuring table ownership and migration privileges for user '${TARGET_APP_USER}'..."
    run_psql "${TARGET_DB}" "
        DO \$\$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
                EXECUTE format('ALTER TABLE public.%I OWNER TO %I;', r.tablename, '${TARGET_APP_USER}');
            END LOOP;
            FOR r IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
                EXECUTE format('ALTER SEQUENCE public.%I OWNER TO %I;', r.sequence_name, '${TARGET_APP_USER}');
            END LOOP;
        END \$\$;
        GRANT ALL ON ALL TABLES IN SCHEMA public TO \"${TARGET_APP_USER}\";
        GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO \"${TARGET_APP_USER}\";
        ALTER SCHEMA public OWNER TO \"${TARGET_APP_USER}\";
    " 2>/dev/null || log_warn "Could not reassign table ownership to '${TARGET_APP_USER}'. Migration DDL may require superuser or table ownership."
fi

TURNS=$(run_psql_query "${TARGET_DB}" "SELECT count(*) FROM conversations;" 2>/dev/null || echo "N/A")
WORKSTREAMS=$(run_psql_query "${TARGET_DB}" "SELECT count(*) FROM workstreams;" 2>/dev/null || echo "N/A")
log_info "Verification — Conversation Turns: ${TURNS}, Workstreams: ${WORKSTREAMS}."
