#!/usr/bin/env bash
#
# Shopixy Kubernetes Platform Bootstrap
#
# Deploys each infrastructure stack (in order) by running its local
# bootstrap.sh, then prints a pass/fail summary and writes a log file.
#
# Usage:
#   sudo ./bootstrap.sh                # deploy all stacks
#   sudo ./bootstrap.sh --list         # list stacks and exit
#   sudo ./bootstrap.sh --only redis,minio     # deploy only these stacks
#   sudo ./bootstrap.sh --skip firewall,mongo-native  # deploy all except these
#   sudo ./bootstrap.sh --dry-run      # show what would run, don't execute
#
set -Eeuo pipefail

PLATFORM_VERSION="1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"

# All child stack scripts expect KUBECONFIG to already be set. Export it
# once here so every "bash $STACK/bootstrap.sh" call inherits it, instead
# of relying on each stack script to set it individually.
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

###############################################
# Stacks (deployed in this order)
###############################################
STACKS=(
    firewall
    traefik
    metallb
    cert-manager
    minio
    postgresql
    mongo-native
    redis
    rabbitmq
    opensearch
    prometheus
    grafana
    network-policies
)

REQUIRED_BINARIES=(kubectl helm)

###############################################
# Colors (disabled automatically if not a TTY)
###############################################
if [ -t 1 ]; then
    C_RESET="\033[0m"; C_BOLD="\033[1m"
    C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_CYAN="\033[36m"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

###############################################
# Options
###############################################
ONLY=()
SKIP=()
DRY_RUN=false

###############################################
# Helpers
###############################################
log() {
    # Prints to stdout and appends (uncolored) to the log file.
    local msg="$1"
    echo -e "$msg"
    echo -e "$msg" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE"
}

banner() {
    local title="$1"
    log ""
    log "${C_CYAN}======================================================${C_RESET}"
    log "${C_CYAN} ${title}${C_RESET}"
    log "${C_CYAN}======================================================${C_RESET}"
}

die() {
    log "${C_RED}[ERROR]${C_RESET} $1"
    exit "${2:-1}"
}

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

contains() {
    local needle="$1"; shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

on_error() {
    local exit_code=$?
    local line_no=$1
    log "${C_RED}[FATAL]${C_RESET} Unexpected error (exit ${exit_code}) at line ${line_no}."
    log "See full log: ${LOG_FILE}"
    exit "$exit_code"
}

on_interrupt() {
    log ""
    log "${C_YELLOW}[ABORTED]${C_RESET} Bootstrap interrupted by user."
    exit 130
}

trap 'on_error $LINENO' ERR
trap on_interrupt INT TERM

###############################################
# Argument parsing
###############################################
while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            IFS=',' read -r -a ONLY <<< "${2:-}"
            shift 2
            ;;
        --skip)
            IFS=',' read -r -a SKIP <<< "${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --list)
            printf '%s\n' "${STACKS[@]}"
            exit 0
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

###############################################
# Pre-flight checks
###############################################
mkdir -p "$LOG_DIR"

banner "Shopixy Kubernetes Platform Bootstrap  —  Version ${PLATFORM_VERSION}"

if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root.$(printf '\n\n')       Try: sudo ./bootstrap.sh"
fi

for BIN in "${REQUIRED_BINARIES[@]}"; do
    command -v "$BIN" >/dev/null 2>&1 || die "Missing required dependency: $BIN"
done

if [ ! -f "$KUBECONFIG" ]; then
    die "KUBECONFIG file not found: $KUBECONFIG"
fi

# Validate any names passed via --only/--skip actually exist.
for name in "${ONLY[@]:-}" "${SKIP[@]:-}"; do
    [ -z "$name" ] && continue
    contains "$name" "${STACKS[@]}" || die "Unknown stack name: '$name' (see --list)"
done

log "Log file: ${LOG_FILE}"

###############################################
# Build final deploy list
###############################################
DEPLOY_LIST=()
for STACK in "${STACKS[@]}"; do
    if [ "${#ONLY[@]}" -gt 0 ] && ! contains "$STACK" "${ONLY[@]}"; then
        continue
    fi
    if [ "${#SKIP[@]}" -gt 0 ] && contains "$STACK" "${SKIP[@]}"; then
        continue
    fi
    DEPLOY_LIST+=("$STACK")
done

if [ "${#DEPLOY_LIST[@]}" -eq 0 ]; then
    die "No stacks selected to deploy (check --only/--skip values)."
fi

###############################################
# Deploy
###############################################
SUCCESS=()
FAILED=()
MISSING=()
TOTAL="${#DEPLOY_LIST[@]}"
INDEX=1
START_TIME=$(date +%s)

for STACK in "${DEPLOY_LIST[@]}"; do
    banner "[${INDEX}/${TOTAL}] Deploying: ${STACK}"

    STACK_DIR="$ROOT_DIR/$STACK"
    if [ ! -d "$STACK_DIR" ]; then
        log "${C_YELLOW}[MISSING]${C_RESET} Directory not found: $STACK_DIR"
        MISSING+=("$STACK")
        INDEX=$((INDEX + 1))
        continue
    fi

    if [ -f "$STACK_DIR/bootstrap.sh" ]; then
        SCRIPT="$STACK_DIR/bootstrap.sh"
    elif [ -f "$STACK_DIR/scripts/bootstrap.sh" ]; then
        SCRIPT="$STACK_DIR/scripts/bootstrap.sh"
    else
        log "${C_YELLOW}[MISSING]${C_RESET} bootstrap.sh not found for '$STACK'"
        MISSING+=("$STACK")
        INDEX=$((INDEX + 1))
        continue
    fi

    if $DRY_RUN; then
        log "${C_YELLOW}[DRY-RUN]${C_RESET} Would run: $SCRIPT"
        INDEX=$((INDEX + 1))
        continue
    fi

    if [ ! -x "$SCRIPT" ] && ! chmod +x "$SCRIPT" 2>/dev/null; then
        log "${C_YELLOW}[WARN]${C_RESET} Could not set execute bit on $SCRIPT, running via bash anyway."
    fi

    STACK_START=$(date +%s)
    # set -o pipefail (enabled above) makes this if-condition reflect the
    # exit status of "bash $SCRIPT", not the exit status of tee.
    if bash "$SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
        STACK_ELAPSED=$(( $(date +%s) - STACK_START ))
        log "${C_GREEN}[PASS]${C_RESET} ${STACK} (${STACK_ELAPSED}s)"
        SUCCESS+=("$STACK")
    else
        STACK_ELAPSED=$(( $(date +%s) - STACK_START ))
        log "${C_RED}[FAIL]${C_RESET} ${STACK} (${STACK_ELAPSED}s)"
        FAILED+=("$STACK")
    fi

    INDEX=$((INDEX + 1))
done

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

###############################################
# Summary
###############################################
banner "Platform Bootstrap Summary"

log ""
log "${C_BOLD}Succeeded (${#SUCCESS[@]}):${C_RESET}"
for STACK in "${SUCCESS[@]:-}"; do
    [ -z "$STACK" ] && continue
    log "   ${C_GREEN}✓${C_RESET} $STACK"
done

log ""
log "${C_BOLD}Failed (${#FAILED[@]}):${C_RESET}"
for STACK in "${FAILED[@]:-}"; do
    [ -z "$STACK" ] && continue
    log "   ${C_RED}✗${C_RESET} $STACK"
done

log ""
log "${C_BOLD}Missing (${#MISSING[@]}):${C_RESET}"
for STACK in "${MISSING[@]:-}"; do
    [ -z "$STACK" ] && continue
    log "   ${C_YELLOW}?${C_RESET} $STACK  (folder or bootstrap.sh not found — did you run 'git pull'?)"
done

if ! $DRY_RUN; then
    SUCCESS_RATE=$(( ${#SUCCESS[@]} * 100 / TOTAL ))
    log ""
    log "Success Rate: ${SUCCESS_RATE}%  (${#SUCCESS[@]}/${TOTAL})"
fi

log ""
log "Total time: ${TOTAL_ELAPSED}s"
log "Full log:   ${LOG_FILE}"

if $DRY_RUN; then
    banner "Dry run complete — no changes were made"
    exit 0
fi

if [ "${#FAILED[@]}" -gt 0 ] || [ "${#MISSING[@]}" -gt 0 ]; then
    banner "${C_RED}Platform Bootstrap FAILED${C_RESET}"
    exit 1
fi

banner "${C_GREEN}Platform Bootstrap Completed Successfully${C_RESET}"
log ""
log "Next step:"
log ""
log "   sudo ./validate.sh"
log ""
