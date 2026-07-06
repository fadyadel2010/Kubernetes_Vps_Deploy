#!/usr/bin/env bash
#
# Shopixy Kubernetes Platform Validation
#
# Executes each infrastructure stack validate.sh (in order),
# collects results, generates a health report and writes
# a validation log.
#
# Usage:
#   sudo ./validate.sh
#   sudo ./validate.sh --list
#   sudo ./validate.sh --only redis,minio
#   sudo ./validate.sh --skip grafana,prometheus
#   sudo ./validate.sh --dry-run
#

set -Eeuo pipefail

PLATFORM_VERSION="1.1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/validate-$(date +%Y%m%d-%H%M%S).log"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

###############################################################
# Validation Order
###############################################################

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

###############################################################
# Dependencies
###############################################################

REQUIRED_BINARIES=(
    kubectl
    helm
)

###############################################################
# Colors
###############################################################

if [ -t 1 ]; then

    C_RESET="\033[0m"
    C_BOLD="\033[1m"

    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_CYAN="\033[36m"

else

    C_RESET=""
    C_BOLD=""

    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""

fi

###############################################################
# Options
###############################################################

ONLY=()

SKIP=()

DRY_RUN=false

###############################################################
# Helpers
###############################################################

log() {

    local msg="$1"

    echo -e "$msg"

    echo -e "$msg" \
        | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
        >> "$LOG_FILE"

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

cat <<EOF

Shopixy Kubernetes Platform Validation

Usage:

  sudo ./validate.sh

Options:

  --list

      List available stacks.

  --only stack1,stack2

      Validate only selected stacks.

  --skip stack1,stack2

      Skip selected stacks.

  --dry-run

      Show what would execute.

  --help

      Show this help.

EOF

exit 0

}

contains() {

    local needle="$1"

    shift

    for item in "$@"
    do
        [ "$item" = "$needle" ] && return 0
    done

    return 1

}

# Count pods matching a given status from an already-fetched
# pod list (avoids re-querying the API server for every status).
count_pods() {

    local STATUS="$1"

    echo "$PODS" \
        | awk -v s="$STATUS" '$4==s{c++} END{print c+0}'

}

###############################################################
# Traps
###############################################################

on_error() {

    local EXIT_CODE=$?

    local LINE=$1

    log "${C_RED}[FATAL]${C_RESET} Unexpected error (exit ${EXIT_CODE}) at line ${LINE}"

    log "See full log: ${LOG_FILE}"

    exit "$EXIT_CODE"

}

on_interrupt() {

    log ""

    log "${C_YELLOW}[ABORTED]${C_RESET} Validation interrupted."

    exit 130

}

trap 'on_error $LINENO' ERR

trap on_interrupt INT TERM

###############################################################
# Parse Arguments
###############################################################

while [ $# -gt 0 ]
do

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

###############################################################
# Pre-flight
###############################################################

mkdir -p "$LOG_DIR"

banner "Shopixy Kubernetes Platform Validation — Version ${PLATFORM_VERSION}"

if [ "$(id -u)" -ne 0 ]
then

    die "This script must be run as root.

Try:

sudo ./validate.sh"

fi

for BIN in "${REQUIRED_BINARIES[@]}"
do

    command -v "$BIN" >/dev/null 2>&1 \
        || die "Missing dependency: $BIN"

done

if [ ! -f "$KUBECONFIG" ]
then

    die "KUBECONFIG not found:

$KUBECONFIG"

fi

for NAME in "${ONLY[@]:-}" "${SKIP[@]:-}"
do

    [ -z "$NAME" ] && continue

    contains "$NAME" "${STACKS[@]}" \
        || die "Unknown stack name:

$NAME"

done

log "Validation started : $(date)"

log "Log file           : ${LOG_FILE}"

###############################################################
# Build Validation List
###############################################################

VALIDATE_LIST=()

for STACK in "${STACKS[@]}"
do

    if [ "${#ONLY[@]}" -gt 0 ] &&
       ! contains "$STACK" "${ONLY[@]}"
    then
        continue
    fi

    if [ "${#SKIP[@]}" -gt 0 ] &&
       contains "$STACK" "${SKIP[@]}"
    then
        continue
    fi

    VALIDATE_LIST+=("$STACK")

done

if [ "${#VALIDATE_LIST[@]}" -eq 0 ]
then

    die "No stacks selected."

fi

###############################################################
# Validation
###############################################################

SUCCESS=()

FAILED=()

MISSING=()

TOTAL="${#VALIDATE_LIST[@]}"

INDEX=1

START_TIME=$(date +%s)

for STACK in "${VALIDATE_LIST[@]}"
do

    banner "[${INDEX}/${TOTAL}] Validating: ${STACK}"

    STACK_DIR="$ROOT_DIR/$STACK"

    ###########################################################
    # Directory
    ###########################################################

    if [ ! -d "$STACK_DIR" ]
    then

        log "${C_YELLOW}[MISSING]${C_RESET} Directory not found:"

        log "  $STACK_DIR"

        MISSING+=("$STACK")

        INDEX=$((INDEX + 1))

        continue

    fi

    ###########################################################
    # validate.sh
    ###########################################################

    if [ -f "$STACK_DIR/validate.sh" ]
    then

        SCRIPT="$STACK_DIR/validate.sh"

    elif [ -f "$STACK_DIR/scripts/validate.sh" ]
    then

        SCRIPT="$STACK_DIR/scripts/validate.sh"

    else

        log "${C_YELLOW}[MISSING]${C_RESET} validate.sh not found"

        MISSING+=("$STACK")

        INDEX=$((INDEX + 1))

        continue

    fi

    ###########################################################
    # Dry Run
    ###########################################################

    if $DRY_RUN
    then

        log "${C_YELLOW}[DRY-RUN]${C_RESET} Would run:"

        log "  $SCRIPT"

        INDEX=$((INDEX + 1))

        continue

    fi

    ###########################################################
    # Execute Permission
    ###########################################################

    if [ ! -x "$SCRIPT" ]
    then

        chmod +x "$SCRIPT" 2>/dev/null || true

    fi

    ###########################################################
    # Execute Validation
    ###########################################################

    STACK_START=$(date +%s)

    if bash "$SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    then

        STACK_TIME=$(( $(date +%s) - STACK_START ))

        log "${C_GREEN}[PASS]${C_RESET} ${STACK} (${STACK_TIME}s)"

        SUCCESS+=("$STACK")

    else

        STACK_TIME=$(( $(date +%s) - STACK_START ))

        log "${C_RED}[FAIL]${C_RESET} ${STACK} (${STACK_TIME}s)"

        FAILED+=("$STACK")

    fi

    INDEX=$((INDEX + 1))

done

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))


###############################################################
# Summary
###############################################################

banner "Platform Validation Summary"

if $DRY_RUN
then

    ###########################################################
    # Dry Run Summary
    ###########################################################

    log ""

    log "${C_BOLD}Dry Run Summary${C_RESET}"

    log ""

    log "Stacks Selected : ${TOTAL}"
    log "Stacks Found    : $(( TOTAL - ${#MISSING[@]} ))"

    if [ "${#MISSING[@]}" -gt 0 ]
    then

        log ""

        log "${C_BOLD}Missing (${#MISSING[@]}):${C_RESET}"

        for STACK in "${MISSING[@]:-}"
        do

            [ -z "$STACK" ] && continue

            log "   ${C_YELLOW}?${C_RESET} $STACK (folder or validate.sh not found)"

        done

    fi

    log ""

    log "No validation was executed."

    banner "Dry Run Completed"

    exit 0

fi

###############################################################
# Success
###############################################################

log ""

log "${C_BOLD}Succeeded (${#SUCCESS[@]}):${C_RESET}"

for STACK in "${SUCCESS[@]:-}"
do

    [ -z "$STACK" ] && continue

    log "   ${C_GREEN}✓${C_RESET} $STACK"

done

###############################################################
# Failed
###############################################################

log ""

log "${C_BOLD}Failed (${#FAILED[@]}):${C_RESET}"

for STACK in "${FAILED[@]:-}"
do

    [ -z "$STACK" ] && continue

    log "   ${C_RED}✗${C_RESET} $STACK"

done

###############################################################
# Missing
###############################################################

log ""

log "${C_BOLD}Missing (${#MISSING[@]}):${C_RESET}"

for STACK in "${MISSING[@]:-}"
do

    [ -z "$STACK" ] && continue

    log "   ${C_YELLOW}?${C_RESET} $STACK (folder or validate.sh not found)"

done

###############################################################
# Infrastructure Health
###############################################################

banner "Infrastructure Health"

for STACK in "${STACKS[@]}"
do

    if contains "$STACK" "${SUCCESS[@]:-}"
    then

        log "   ${C_GREEN}✓${C_RESET} $STACK"

    elif contains "$STACK" "${FAILED[@]:-}"
    then

        log "   ${C_RED}✗${C_RESET} $STACK"

    elif contains "$STACK" "${MISSING[@]:-}"
    then

        log "   ${C_YELLOW}?${C_RESET} $STACK"

    fi

done

###############################################################
# Success Rate
###############################################################

SUCCESS_RATE=$(( ${#SUCCESS[@]} * 100 / TOTAL ))

log ""

log "Success Rate : ${SUCCESS_RATE}% (${#SUCCESS[@]}/${TOTAL})"

#######################################################
# Cluster Pod Summary
#######################################################

# Fetch the pod list once and reuse it for every count,
# instead of hitting the API server on every awk pass.
PODS="$($KUBECTL get pods -A --no-headers)"

TOTAL_PODS=$(echo "$PODS" | grep -c . || true)

RUNNING=$(count_pods "Running")
COMPLETED=$(count_pods "Completed")
PENDING=$(count_pods "Pending")
CRASHLOOP=$(count_pods "CrashLoopBackOff")
IMAGE_PULL=$(count_pods "ImagePullBackOff")
ERRORS=$(count_pods "Error")
EVICTED=$(count_pods "Evicted")
UNKNOWN=$(count_pods "Unknown")

banner "Cluster Pod Summary"

log "$(printf "%-24s %s" "Total Pods :" "$TOTAL_PODS")"
log "$(printf "%-24s %s" "Running :" "$RUNNING")"
log "$(printf "%-24s %s" "Completed :" "$COMPLETED")"
log "$(printf "%-24s %s" "Pending :" "$PENDING")"

log ""

log "$(printf "%-24s %s" "CrashLoopBackOff :" "$CRASHLOOP")"
log "$(printf "%-24s %s" "ImagePullBackOff :" "$IMAGE_PULL")"
log "$(printf "%-24s %s" "Error :" "$ERRORS")"
log "$(printf "%-24s %s" "Evicted :" "$EVICTED")"
log "$(printf "%-24s %s" "Unknown :" "$UNKNOWN")"

###############################################################
# Timing
###############################################################

log ""

log "Validation Started : $(date -d "@$START_TIME" '+%F %T' 2>/dev/null || date)"

log "Validation Ended   : $(date)"

log "Total Time         : ${TOTAL_ELAPSED}s"

log "Log File           : ${LOG_FILE}"

###############################################################
# Final Result
###############################################################

if [ "${#FAILED[@]}" -gt 0 ] || [ "${#MISSING[@]}" -gt 0 ]
then

    banner "${C_RED}Platform Validation FAILED${C_RESET}"

    exit 1

fi

banner "${C_GREEN}Platform Healthy${C_RESET}"

exit 0
