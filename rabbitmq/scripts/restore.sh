#!/usr/bin/env bash
set -Eeuo pipefail
###############################################
# RabbitMQ Kubernetes Restore
# Shopixy Infrastructure
###############################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_ROOT="$PROJECT_ROOT/backups/rabbitmq"
NAMESPACE="rabbitmq"
STATEFULSET="rabbitmq-server"
###############################################
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}
###############################################
if [ $# -ne 1 ]; then
    echo
    echo "Usage:"
    echo "  ./restore.sh <backup-file>"
    echo
    exit 1
fi
ARCHIVE="$1"
if [[ ! "$ARCHIVE" = /* ]]; then
    ARCHIVE="$BACKUP_ROOT/$ARCHIVE"
fi
if [ ! -f "$ARCHIVE" ]; then
    log "ERROR: Backup file not found: $ARCHIVE"
    exit 1
fi
###############################################
# Extract
###############################################
TMP_DIR="/tmp/rabbitmq_restore_$$"
mkdir -p "$TMP_DIR"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
log "Extracting archive"
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
###############################################
# Validation
###############################################
for FILE in \
    manifest.json \
    definitions.json \
    cluster-info.txt
do
    if [ ! -f "$TMP_DIR/$FILE" ]; then
        log "ERROR: Missing $FILE in archive"
        exit 1
    fi
done

# FIX 1: Validate that .nodes is a positive integer before using it
NODES=$(jq -r '.nodes' "$TMP_DIR/manifest.json")
if ! [[ "$NODES" =~ ^[1-9][0-9]*$ ]]; then
    log "ERROR: manifest.json '.nodes' is not a valid positive integer (got: '$NODES')"
    exit 1
fi
log "Backup nodes: $NODES"

# FIX 2: Validate per-node tarballs exist before we touch anything
for NODE in $(seq 0 $((NODES - 1))); do
    NODE_TAR="$TMP_DIR/rabbitmq-server-$NODE.tar.gz"
    if [ ! -f "$NODE_TAR" ]; then
        log "ERROR: Missing node tarball: $NODE_TAR"
        exit 1
    fi
done
###############################################
# Confirmation
###############################################
echo
echo "========================================="
echo "WARNING"
echo "========================================="
echo
echo "This operation will overwrite"
echo "RabbitMQ persistent data."
echo
echo "Cluster: $STATEFULSET"
echo "Namespace: $NAMESPACE"
echo "Nodes: $NODES"
echo
echo "Archive:"
echo "$ARCHIVE"
echo
echo "Type YES to continue:"
read -r CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    log "Restore cancelled"
    exit 1
fi
###############################################
# Scale Down
###############################################
log "Scaling RabbitMQ down to 0"
sudo kubectl scale statefulset \
    "$STATEFULSET" \
    -n "$NAMESPACE" \
    --replicas=0

# Wait for all pods to be fully gone before touching PV data.
# kubectl wait --for=delete is the correct tool for this; it exits as soon
# as every matched pod is gone, or times out with a non-zero exit code.
# It also exits non-zero (with "no matching resources") if pods are already
# gone before the command runs, so we fall through to an explicit count check.
log "Waiting for all pods to terminate gracefully (timeout: 300s)"
if sudo kubectl wait pod \
    -n "$NAMESPACE" \
    -l "app.kubernetes.io/name=rabbitmq" \
    --for=delete \
    --timeout=300s 2>/dev/null; then
    log "All pods terminated gracefully"
else
    # Graceful wait timed out or no pods matched. Check what is still running.
    STUCK_PODS=$(sudo kubectl get pods \
        -n "$NAMESPACE" \
        -l "app.kubernetes.io/name=rabbitmq" \
        --no-headers 2>/dev/null)
    POD_COUNT=$(echo "$STUCK_PODS" | grep -c . || true)

    if [ "$POD_COUNT" -eq 0 ]; then
        log "All pods already terminated"
    else
        # Force-delete each stuck pod (grace-period=0) so PV data can be
        # safely restored. This is intentional during a restore operation.
        log "WARNING: $POD_COUNT pod(s) still running after 300s — force-deleting"
        echo "$STUCK_PODS" | awk '{print $1}' | while read -r POD_NAME; do
            log "Force-deleting $POD_NAME"
            sudo kubectl delete pod "$POD_NAME" \
                -n "$NAMESPACE" \
                --grace-period=0 \
                --force 2>/dev/null || true
        done

        # Wait up to 60s for force-deleted pods to disappear
        log "Waiting for force-deleted pods to clear (timeout: 60s)"
        if ! sudo kubectl wait pod \
            -n "$NAMESPACE" \
            -l "app.kubernetes.io/name=rabbitmq" \
            --for=delete \
            --timeout=60s 2>/dev/null; then
            REMAINING=$(sudo kubectl get pods \
                -n "$NAMESPACE" \
                -l "app.kubernetes.io/name=rabbitmq" \
                --no-headers 2>/dev/null | grep -c . || true)
            if [ "$REMAINING" -gt 0 ]; then
                log "ERROR: $REMAINING pod(s) could not be removed — aborting to protect PV data"
                exit 1
            fi
        fi
        log "All pods terminated"
    fi
fi
###############################################
# Restore Node Data
###############################################
for NODE in $(seq 0 $((NODES - 1))); do
    PV_PATH=$(sudo kubectl get pv \
      -o jsonpath="{range .items[?(@.spec.claimRef.name=='persistence-rabbitmq-server-$NODE')]}{.spec.local.path}{end}")

    if [ -z "$PV_PATH" ]; then
        log "ERROR: PV path not found for node $NODE"
        exit 1
    fi

    # FIX 4: Reject PV paths that look unsafe (must be an absolute path,
    # no path-traversal sequences, and no whitespace from a malformed jsonpath result).
    if [[ ! "$PV_PATH" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
        log "ERROR: PV path for node $NODE looks unsafe: '$PV_PATH'"
        exit 1
    fi

    log "Restoring rabbitmq-server-$NODE (PV: $PV_PATH)"

    # backup.sh ran: tar czf - /var/lib/rabbitmq
    # This produces an archive with entries like: var/lib/rabbitmq/mnesia/...
    # (tar strips the leading slash, but keeps the full path tree).
    #
    # Each node's PV is mounted into its pod at /var/lib/rabbitmq, so
    # on the host the data lives at $PV_PATH/var/lib/rabbitmq/...
    #
    # Strategy:
    #   1. Wipe $PV_PATH/var/lib/rabbitmq  (the actual data dir on this PV)
    #   2. Extract the archive into $PV_PATH so entries land at
    #      $PV_PATH/var/lib/rabbitmq/... — exactly where the pod expects them.
    sudo rm -rf "${PV_PATH:?}/var/lib/rabbitmq"

    sudo tar -xzf \
        "$TMP_DIR/rabbitmq-server-$NODE.tar.gz" \
        -C "$PV_PATH"

    log "rabbitmq-server-$NODE restored"
done
###############################################
# Scale Up
###############################################
log "Scaling RabbitMQ up to $NODES"
sudo kubectl scale statefulset \
    "$STATEFULSET" \
    -n "$NAMESPACE" \
    --replicas="$NODES"
###############################################
# Wait
###############################################
log "Waiting for cluster rollout"
sudo kubectl rollout status \
    statefulset/"$STATEFULSET" \
    -n "$NAMESPACE" \
    --timeout=600s
###############################################
# Import Definitions
###############################################
# Import definitions by piping the file through stdin — avoids kubectl cp
# which uses tar internally and fails when the container filesystem is read-only
# (common with the RabbitMQ Operator which mounts the rootfs as read-only).
log "Importing definitions (vhosts, exchanges, queues, bindings, users)"
sudo kubectl exec \
    -n "$NAMESPACE" \
    rabbitmq-server-0 \
    -i \
    -- rabbitmqctl import_definitions /dev/stdin \
    < "$TMP_DIR/definitions.json"
log "Definitions imported"
###############################################
# Validation
###############################################
log "Running validation"
sudo kubectl exec \
    -n "$NAMESPACE" \
    rabbitmq-server-0 \
    -- rabbitmqctl cluster_status
echo
sudo kubectl exec \
    -n "$NAMESPACE" \
    rabbitmq-server-0 \
    -- rabbitmq-diagnostics check_running
echo
log "Restore completed successfully"
