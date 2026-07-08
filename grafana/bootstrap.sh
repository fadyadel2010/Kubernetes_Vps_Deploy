#!/usr/bin/env bash

##################################################
# Shopixy Grafana Production Bootstrap
##################################################
#
# Idempotent bootstrap for the Grafana stack (namespace, secret,
# configmaps, PVC, deployment, service, ingress) with health
# verification and a final resource summary.
#
##################################################

set -Eeuo pipefail

##################################################
# Configuration
##################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-monitoring}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG="$KUBECONFIG_PATH"

PVC_BIND_TIMEOUT="120s"
ROLLOUT_TIMEOUT="600s"
POD_READY_TIMEOUT="300s"

PVC_TERMINATE_MAX_WAIT=120     # seconds
POD_DISCOVERY_MAX_WAIT=120     # seconds
HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=3        # seconds

# Array (not a string) so it survives quoting/expansion correctly.
KUBECTL=(sudo -E kubectl --kubeconfig="$KUBECONFIG_PATH")

REQUIRED_FILES=(
    "namespace.yaml"
    "grafana-secret.yaml"
    "grafana-configmap.yaml"
    "grafana-pvc.yaml"
    "grafana-service.yaml"
    "grafana-deployment.yaml"
    "grafana-ingress.yaml"
    "configmaps/grafana-alerting.yaml"
)

REQUIRED_PROVISIONING_DIRS=(datasources dashboards alerting contactpoints policies)
PROVISIONING_DIR="$SCRIPT_DIR/provisioning"

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

trap 'error "Bootstrap failed at line ${LINENO} (exit code $?). Aborting."' ERR

##################################################
# Dependencies
##################################################

section "Dependency Check"

for BIN in kubectl sudo; do
    if ! command -v "$BIN" >/dev/null 2>&1; then
        error "Missing dependency: $BIN"
        exit 1
    fi
done
ok "Dependencies verified"

##################################################
# Required Files & Provisioning Assets
# (validated up front so we fail fast, before touching the cluster)
##################################################

section "Pre-flight Checks"

for FILE in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$FILE" ]; then
        error "Missing file: $FILE"
        exit 1
    fi
done
ok "Bootstrap manifest files verified"

for DIR in "${REQUIRED_PROVISIONING_DIRS[@]}"; do
    if [ ! -d "$PROVISIONING_DIR/$DIR" ]; then
        error "Missing provisioning directory: $DIR"
        exit 1
    fi
done
ok "Provisioning directories verified"

##################################################
# Alerting Provisioning Validation
##################################################
# Grafana's alerting provisioner crashes the entire pod on startup if any
# alert rule or notification policy references a "receiver" that doesn't
# match a defined contact point (e.g. a leftover placeholder like
# "receiver: empty"). We catch that here, before touching the cluster,
# instead of finding out via a CrashLoopBackOff.

ALERTING_CONFIGMAP="$SCRIPT_DIR/configmaps/grafana-alerting.yaml"

# Grafana always has a built-in default contact point; anything provisioned
# is layered on top of it.
KNOWN_RECEIVERS=("grafana-default-email")

# Collect names of contact points actually defined under provisioning/contactpoints.
while IFS= read -r NAME; do
    NAME="$(echo "$NAME" | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '"'"'"'')"
    [ -n "$NAME" ] && KNOWN_RECEIVERS+=("$NAME")
done < <(find "$PROVISIONING_DIR/contactpoints" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -exec grep -h -E '^\s*-?\s*name:\s*' {} + 2>/dev/null || true)

is_known_receiver() {
    local candidate="$1"
    for KNOWN in "${KNOWN_RECEIVERS[@]}"; do
        [ "$candidate" = "$KNOWN" ] && return 0
    done
    return 1
}

VALIDATION_ERRORS=0

while IFS= read -r RAW_LINE; do
    RECEIVER="$(echo "$RAW_LINE" | sed -E 's/^\s*receiver:\s*//' | tr -d '"'"'"'' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -z "$RECEIVER" ] && continue

    if ! is_known_receiver "$RECEIVER"; then
        error "Alerting config references unknown receiver: '${RECEIVER}' (no matching contact point in provisioning/contactpoints/)"
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    fi
done < <(grep -E '^\s*receiver:\s*' "$ALERTING_CONFIGMAP" 2>/dev/null || true)

if [ "$VALIDATION_ERRORS" -gt 0 ]; then
    error "Found ${VALIDATION_ERRORS} invalid receiver reference(s) in $(basename "$ALERTING_CONFIGMAP")."
    error "Grafana will CrashLoopBackOff on this exact issue if deployed as-is."
    error "Fix it by either: (1) defining a matching contact point under provisioning/contactpoints/,"
    error "or (2) removing the 'notification_settings' override from the affected rule(s) to use the default receiver."
    exit 1
fi
ok "Alerting provisioning validated (no dangling receiver references)"

##################################################
# Namespace
##################################################

section "Namespace"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/namespace.yaml"
ok "Namespace ready"

##################################################
# Secret
##################################################

section "Secret"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/grafana-secret.yaml"
ok "Secret ready"

##################################################
# Configuration
##################################################

section "Configuration"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/grafana-configmap.yaml"
ok "Configuration ready"

##################################################
# Datasources
##################################################

section "Datasources"

"${KUBECTL[@]}" create configmap grafana-datasources \
    --from-file="$PROVISIONING_DIR/datasources" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml \
| "${KUBECTL[@]}" apply -f -

ok "Datasource ConfigMap ready"

##################################################
# Dashboard Provider
##################################################

section "Dashboard Provider"

"${KUBECTL[@]}" create configmap grafana-dashboard-provider \
    --from-file="$PROVISIONING_DIR/dashboards/provider.yaml" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml \
| "${KUBECTL[@]}" apply -f -

ok "Dashboard Provider ready"

##################################################
# Dashboards
##################################################

create_or_replace_configmap() {

    local NAME="$1"
    local FILE="$2"

    "${KUBECTL[@]}" delete configmap \
        "$NAME" \
        -n "$NAMESPACE" \
        --ignore-not-found >/dev/null 2>&1 || true

    "${KUBECTL[@]}" create configmap \
        "$NAME" \
        --from-file="$FILE" \
        -n "$NAMESPACE"
}

section "Dashboards"

for DASHBOARD in "$PROVISIONING_DIR"/dashboards/*.json
do
    NAME=$(basename "$DASHBOARD" .json)

    log "Provisioning dashboard: ${NAME}"

    create_or_replace_configmap \
        "grafana-dashboard-${NAME}" \
        "$DASHBOARD"

    ok "${NAME} dashboard ready"
done

ok "All dashboards provisioned"

##################################################
# Alerting ConfigMap
##################################################

section "Alerting"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/configmaps/grafana-alerting.yaml"
ok "Alerting ConfigMap ready"

##################################################
# Persistent Volume
##################################################

section "Persistent Volume"

log "Checking for a PVC still terminating from a previous run..."
WAITED=0
while "${KUBECTL[@]}" get pvc grafana-storage -n "$NAMESPACE" >/dev/null 2>&1; do
    DELETING=$("${KUBECTL[@]}" get pvc grafana-storage -n "$NAMESPACE" \
        -o jsonpath='{.metadata.deletionTimestamp}')

    [ -z "$DELETING" ] && break

    if [ "$WAITED" -ge "$PVC_TERMINATE_MAX_WAIT" ]; then
        error "Existing PVC did not finish terminating within ${PVC_TERMINATE_MAX_WAIT}s"
        exit 1
    fi

    log "Existing PVC is terminating... (${WAITED}s/${PVC_TERMINATE_MAX_WAIT}s)"
    sleep 3
    WAITED=$((WAITED + 3))
done

"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/grafana-pvc.yaml"

##################################################
# Service
##################################################

section "Service"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/grafana-service.yaml"
ok "Service ready"

##################################################
# Deployment
##################################################

section "Deployment"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/grafana-deployment.yaml"

log "Waiting for Grafana Deployment rollout..."
"${KUBECTL[@]}" rollout status \
    deployment/grafana \
    -n "$NAMESPACE" \
    --timeout="$ROLLOUT_TIMEOUT"
ok "Deployment rollout completed"

##################################################
# Persistent Volume Bind
##################################################
# The PVC only binds once a pod that mounts it has been scheduled,
# which happens as part of the Deployment rollout above. Waiting for
# it any earlier than this will time out.

log "Waiting for Persistent Volume..."
"${KUBECTL[@]}" wait \
    --for=jsonpath='{.status.phase}'=Bound \
    pvc/grafana-storage \
    -n "$NAMESPACE" \
    --timeout="$PVC_BIND_TIMEOUT"
ok "Persistent Volume ready"

##################################################
# Wait for Pod
##################################################

log "Locating Grafana pod..."

POD=""
WAITED=0
while [ -z "$POD" ]; do
    POD=$("${KUBECTL[@]}" get pods \
        -n "$NAMESPACE" \
        -l app=grafana \
        -o jsonpath='{.items[0].metadata.name}' \
        2>/dev/null || true)

    [ -n "$POD" ] && break

    if [ "$WAITED" -ge "$POD_DISCOVERY_MAX_WAIT" ]; then
        error "No Grafana pod appeared within ${POD_DISCOVERY_MAX_WAIT}s"
        exit 1
    fi

    sleep 2
    WAITED=$((WAITED + 2))
done
log "Pod: $POD"

"${KUBECTL[@]}" wait \
    --for=condition=Ready \
    pod/"$POD" \
    -n "$NAMESPACE" \
    --timeout="$POD_READY_TIMEOUT"
ok "Pod Ready"

##################################################
# Health Check
##################################################

section "Grafana Health"

HEALTHY=""
for ((i = 1; i <= HEALTH_CHECK_RETRIES; i++)); do
    RESPONSE=$("${KUBECTL[@]}" exec -n "$NAMESPACE" "$POD" -- \
        sh -c 'curl -s http://localhost:3000/api/health || wget -qO- http://localhost:3000/api/health' \
        2>/dev/null || true)

    if echo "$RESPONSE" | grep -q '"database":[[:space:]]*"ok"'; then
        HEALTHY="yes"
        break
    fi

    log "Health check attempt ${i}/${HEALTH_CHECK_RETRIES} not ready yet, retrying in ${HEALTH_CHECK_INTERVAL}s..."
    sleep "$HEALTH_CHECK_INTERVAL"
done

if [ -z "$HEALTHY" ]; then
    error "Grafana Health API did not report a healthy database after ${HEALTH_CHECK_RETRIES} attempts"
    exit 1
fi
ok "Health API"

##################################################
# Dashboard Verification
##################################################

section "Dashboard Verification"

if "${KUBECTL[@]}" logs deployment/grafana -n "$NAMESPACE" | grep -q "Cannot read directory"; then
    error "Dashboard provisioning failed"
    exit 1
fi

ok "Dashboard provisioning verified"

##################################################
# Ingress
##################################################

section "Ingress"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/grafana-ingress.yaml"
ok "Ingress applied"

##################################################
# Verification
##################################################

section "Verification"

AVAILABLE=$("${KUBECTL[@]}" get deployment grafana -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}')

if [ "${AVAILABLE:-0}" -lt 1 ]; then
    error "Deployment is not available"
    exit 1
fi
ok "Deployment verified (${AVAILABLE} replica(s) available)"

"${KUBECTL[@]}" get svc grafana -n "$NAMESPACE" >/dev/null
ok "Service verified"

"${KUBECTL[@]}" get pvc grafana-storage -n "$NAMESPACE" >/dev/null
ok "PVC verified"

"${KUBECTL[@]}" get ingress grafana -n "$NAMESPACE" >/dev/null
ok "Ingress verified"

"${KUBECTL[@]}" get configmap grafana-config -n "$NAMESPACE" >/dev/null
ok "Configuration verified"

"${KUBECTL[@]}" get configmap grafana-alerting-postgres -n "$NAMESPACE" >/dev/null
ok "Alerting ConfigMap verified"

section "Grafana Bootstrap Completed Successfully"

##################################################
# Provisioning Summary
##################################################

section "Provisioning Summary"

for DIR in "${REQUIRED_PROVISIONING_DIRS[@]}"; do
    COUNT=$(find "$PROVISIONING_DIR/$DIR" -type f | wc -l)
    printf "[OK] %-15s %3d file(s)\n" "$DIR" "$COUNT"
done

##################################################
# Final Summary
##################################################

section "Running Resources"

echo
echo "--- Deployment ---"
"${KUBECTL[@]}" get deployment grafana -n "$NAMESPACE"

echo
echo "--- Pod ---"
"${KUBECTL[@]}" get pods -n "$NAMESPACE" -l app=grafana

echo
echo "--- Service ---"
"${KUBECTL[@]}" get svc grafana -n "$NAMESPACE"

echo
echo "--- Ingress ---"
"${KUBECTL[@]}" get ingress grafana -n "$NAMESPACE"

echo
echo "--- Persistent Volume ---"
"${KUBECTL[@]}" get pvc grafana-storage -n "$NAMESPACE"

echo
echo "--- ConfigMaps ---"
"${KUBECTL[@]}" get configmap grafana-config grafana-alerting-postgres -n "$NAMESPACE"

section "Grafana Production Bootstrap Completed Successfully"
