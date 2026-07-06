#!/usr/bin/env bash

##################################################
# Shopixy Grafana Validation
##################################################
#
# Post-deploy health check for the Grafana stack. Verifies the
# Deployment, Pod, Health API, and supporting resources, and dumps
# diagnostics automatically if anything looks unhealthy.
#
##################################################

set -Eeuo pipefail

##################################################
# Configuration
##################################################

NAMESPACE="${NAMESPACE:-monitoring}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG="$KUBECONFIG_PATH"

HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=3        # seconds

# Array (not a string) so it survives quoting/expansion correctly.
KUBECTL=(sudo -E kubectl --kubeconfig="$KUBECONFIG_PATH")

##################################################
# Logging helpers
##################################################

log()   { printf '%s [INFO]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok()    { printf '%s [OK]    %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '%s [ERROR] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

section() {
    echo
    echo "======================================================"
    echo " $*"
    echo "======================================================"
}

# Dump pod diagnostics automatically on failure, so a failed run gives you
# the same information you'd otherwise have to go collect by hand.
dump_diagnostics() {
    warn "Dumping diagnostics to help troubleshoot..."
    echo
    echo "--- Pods ---"
    "${KUBECTL[@]}" get pods -n "$NAMESPACE" -l app=grafana -o wide || true

    if [ -n "${POD:-}" ]; then
        echo
        echo "--- Describe Pod: $POD ---"
        "${KUBECTL[@]}" describe pod -n "$NAMESPACE" "$POD" || true

        echo
        echo "--- Recent Logs: $POD ---"
        "${KUBECTL[@]}" logs -n "$NAMESPACE" "$POD" --tail=50 || true
        "${KUBECTL[@]}" logs -n "$NAMESPACE" "$POD" --tail=50 --previous 2>/dev/null || true
    fi

    echo
    echo "--- Recent Events ---"
    "${KUBECTL[@]}" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
}

trap 'error "Validation failed at line ${LINENO}. See diagnostics below."; dump_diagnostics' ERR

##################################################
# Dependencies
##################################################

section "Dependency Check"

# jq is required locally to parse the Health API response.
# curl is checked inside the pod itself (see Health Check section) since
# that's where it actually runs, not on this host.
for BIN in kubectl sudo jq; do
    if ! command -v "$BIN" >/dev/null 2>&1; then
        error "Missing dependency: $BIN"
        exit 1
    fi
done
ok "Dependencies verified"

##################################################
# Deployment
##################################################

section "Deployment"

AVAILABLE=$("${KUBECTL[@]}" get deployment grafana -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)

if ! [[ "${AVAILABLE:-0}" =~ ^[0-9]+$ ]] || [ "${AVAILABLE:-0}" -lt 1 ]; then
    error "Grafana deployment is not available (availableReplicas=${AVAILABLE:-<empty>})"
    exit 1
fi
ok "Deployment healthy (${AVAILABLE} replica(s) available)"

##################################################
# Pod
##################################################

section "Pod"

# Prefer a Running pod if multiple match the label (e.g. an old pod still
# terminating alongside a freshly rolled-out one).
POD=$("${KUBECTL[@]}" get pods -n "$NAMESPACE" -l app=grafana \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$POD" ]; then
    # Fall back to whatever exists, so diagnostics still have a pod to inspect.
    POD=$("${KUBECTL[@]}" get pods -n "$NAMESPACE" -l app=grafana \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [ -z "$POD" ]; then
    error "No Grafana pod found in namespace '$NAMESPACE'"
    dump_diagnostics
    exit 1
fi
ok "Pod: $POD"

##################################################
# Grafana Health API
##################################################

section "Health Check"

HEALTHY=""
for ((i = 1; i <= HEALTH_CHECK_RETRIES; i++)); do
    RESPONSE=$("${KUBECTL[@]}" exec -n "$NAMESPACE" "$POD" -- \
        sh -c 'curl -s http://localhost:3000/api/health || wget -qO- http://localhost:3000/api/health' \
        2>/dev/null || true)

    if [ -n "$RESPONSE" ]; then
        DB_STATUS=$(echo "$RESPONSE" | jq -r '.database' 2>/dev/null || true)
        if [ "$DB_STATUS" = "ok" ]; then
            HEALTHY="yes"
            break
        fi
    fi

    log "Health check attempt ${i}/${HEALTH_CHECK_RETRIES} not ready yet, retrying in ${HEALTH_CHECK_INTERVAL}s..."
    sleep "$HEALTH_CHECK_INTERVAL"
done

if [ -z "$HEALTHY" ]; then
    error "Grafana Health API did not report a healthy database after ${HEALTH_CHECK_RETRIES} attempts"
    dump_diagnostics
    exit 1
fi
ok "Health API"

##################################################
# Resources
##################################################

section "Resources"

"${KUBECTL[@]}" get pvc grafana-storage -n "$NAMESPACE" >/dev/null
ok "PVC"

"${KUBECTL[@]}" get svc grafana -n "$NAMESPACE" >/dev/null
ok "Service"

"${KUBECTL[@]}" get ingress grafana -n "$NAMESPACE" >/dev/null
ok "Ingress"

"${KUBECTL[@]}" get configmap grafana-config -n "$NAMESPACE" >/dev/null
ok "ConfigMap"

"${KUBECTL[@]}" get configmap grafana-alerting -n "$NAMESPACE" >/dev/null
ok "Alerting ConfigMap"

##################################################
# Summary
##################################################

section "Running Pods"
"${KUBECTL[@]}" get pods -n "$NAMESPACE"

section "Services"
"${KUBECTL[@]}" get svc -n "$NAMESPACE"

section "Ingress"
"${KUBECTL[@]}" get ingress -n "$NAMESPACE"

section "Grafana Validation Completed Successfully"
