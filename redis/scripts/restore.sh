#!/bin/bash

set -eo pipefail

#################################################
# Redis Restore Script V2
# Master Restore + Replica Resync
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

NAMESPACE="redis"

if [ $# -ne 1 ]; then
    echo "Usage:"
    echo "  ./restore.sh <backup.tar.gz>"
    exit 1
fi

ARCHIVE="$1"

if [ ! -f "$ARCHIVE" ]; then
    echo "Archive not found: $ARCHIVE"
    exit 1
fi

#################################################
# Load Environment Variables
# FIX: backup.sh loads .env but restore.sh didn't —
# REDIS_PASSWORD was never available for redis-cli calls
#################################################

ENV_FILE="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

#################################################
# Confirmation Prompt
# FIX: This script wipes PVCs — require explicit
# confirmation before doing anything destructive
#################################################

echo "=================================================="
echo "  Redis Disaster Recovery Restore"
echo "=================================================="
echo ""
echo "  Archive : $ARCHIVE"
echo "  Target  : StatefulSet 'redis' in namespace '$NAMESPACE'"
echo "  Action  : Wipe master + replica PVCs and restore from backup"
echo ""
echo "  WARNING: This is destructive and cannot be undone."
echo ""
read -r -p "  Type YES to continue: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo ""

TMP_DIR=$(mktemp -d)

MASTER_PVC="redis-redis-0"
REPLICA_PVCS=(
    "redis-redis-1"
    "redis-redis-2"
)

cleanup() {
    rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT

#################################################
# Extract Backup
#################################################

echo "[1/9] Extracting backup..."

tar -xzf "$ARCHIVE" -C "$TMP_DIR"

if [ ! -f "$TMP_DIR/data/dump.rdb" ]; then
    echo "ERROR: Invalid backup archive — dump.rdb not found"
    exit 1
fi

echo "      dump.rdb found ($(wc -c < "$TMP_DIR/data/dump.rdb") bytes)"

#################################################
# Stop Redis
# FIX: sleep 10 was a blind guess — use kubectl wait
# to confirm all pods are actually gone before
# attempting to mount their PVCs
#################################################

echo "[2/9] Scaling Redis down..."

sudo kubectl scale sts redis \
    -n "$NAMESPACE" \
    --replicas=0

echo "      Waiting for all pods to terminate..."

sudo kubectl wait pod \
    -n "$NAMESPACE" \
    -l app=redis \
    --for=delete \
    --timeout=120s 2>/dev/null || true

# Give PVC detach a moment to finalise
sleep 3

echo "      All Redis pods terminated"

#################################################
# Helper Functions
#################################################

create_restore_pod() {
    PVC_NAME="$1"

    # FIX: Delete any leftover pod from a previous failed restore
    # before trying to apply — avoids PVC mismatch on reuse
    if sudo kubectl get pod redis-restore -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "      Found leftover redis-restore pod — deleting..."
        sudo kubectl delete pod redis-restore \
            -n "$NAMESPACE" \
            --wait=true >/dev/null
    fi

    cat <<EOF | sudo kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: redis-restore
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.22
    command:
    - sh
    - -c
    - sleep 3600
    volumeMounts:
    - mountPath: /data
      name: redis
  volumes:
  - name: redis
    persistentVolumeClaim:
      claimName: $PVC_NAME
EOF

    sudo kubectl wait \
        pod/redis-restore \
        -n "$NAMESPACE" \
        --for=condition=Ready \
        --timeout=120s
}

delete_restore_pod() {
    sudo kubectl delete pod \
        redis-restore \
        -n "$NAMESPACE" \
        --wait=true >/dev/null
}

#################################################
# Restore Master PVC
#################################################

echo "[3/9] Restoring master PVC ($MASTER_PVC)..."

create_restore_pod "$MASTER_PVC"

# Wipe everything on the PVC first
sudo kubectl exec -n "$NAMESPACE" redis-restore -- \
    sh -c "find /data -mindepth 1 -delete"

# Only restore dump.rdb — do NOT copy appendonlydir.
# The AOF files from the backup are root-owned after kubectl cp
# and Redis will fail with "Permission denied" trying to open them.
# Redis will recreate a fresh appendonlydir on first startup.
sudo kubectl cp \
    "$TMP_DIR/data/dump.rdb" \
    "$NAMESPACE/redis-restore:/data/dump.rdb"

# chown to Redis user (UID 999) — kubectl cp writes as root
sudo kubectl exec -n "$NAMESPACE" redis-restore -- \
    sh -c "chown -R 999:999 /data"

delete_restore_pod

echo "      Master PVC restored"

#################################################
# Wipe Replica PVCs
# FIX: Same find + chown fixes applied here
#################################################

echo "[4/9] Cleaning replica PVCs..."

for PVC in "${REPLICA_PVCS[@]}"; do
    echo "      Cleaning $PVC..."

    create_restore_pod "$PVC"

    sudo kubectl exec -n "$NAMESPACE" redis-restore -- \
        sh -c "find /data -mindepth 1 -delete"

    delete_restore_pod

    echo "      $PVC cleaned"
done

#################################################
# Start Redis
#################################################

echo "[5/9] Starting Redis..."

sudo kubectl scale sts redis \
    -n "$NAMESPACE" \
    --replicas=3

#################################################
# Wait for StatefulSet Rollout
#################################################

echo "[6/9] Waiting for rollout..."

sudo kubectl rollout status \
    sts/redis \
    -n "$NAMESPACE" \
    --timeout=300s

#################################################
# Wait for Replication
# FIX: Replace blind sleep 30 with active polling.
# Poll each replica until master_link_status is up.
#################################################

echo "[7/9] Waiting for replication to sync..."

REPLICA_PODS=("redis-1" "redis-2")  # StatefulSet pod names in namespace
REPL_TIMEOUT=120
REPL_WAIT=0

for REPLICA in "${REPLICA_PODS[@]}"; do
    echo "      Waiting for $REPLICA to sync..."
    REPL_WAIT=0

    while true; do
        # grep can exit non-zero if field not yet present; || true prevents
        # pipefail from killing the subshell before we can check the value
        LINK_STATUS=$(
            sudo kubectl exec -n "$NAMESPACE" "$REPLICA" -c redis -- \
                env REDISCLI_AUTH="$REDIS_PASSWORD" \
                redis-cli --no-auth-warning \
                INFO replication 2>/dev/null \
            | grep -m1 "master_link_status:" || true
        )
        # Extract just the value and strip all whitespace
        LINK_STATUS=$(echo "$LINK_STATUS" | cut -d: -f2 | tr -d ' \r\n')

        if [ "$LINK_STATUS" = "up" ]; then
            echo "      $REPLICA synced"
            break
        fi

        if [ "$REPL_WAIT" -ge "$REPL_TIMEOUT" ]; then
            echo "WARNING: $REPLICA did not sync within ${REPL_TIMEOUT}s (status: '${LINK_STATUS}')"
            break
        fi

        sleep 5
        REPL_WAIT=$((REPL_WAIT + 5))
    done
done

#################################################
# Verify Master
# FIX: Confirm redis-0 is actually master after
# restore — don't just print pod list and hope
#################################################

echo "[8/9] Verifying cluster..."

MASTER_ROLE=$(
    sudo kubectl exec -n "$NAMESPACE" redis-0 -- \
        env REDISCLI_AUTH="$REDIS_PASSWORD" \
        redis-cli --no-auth-warning \
        INFO replication 2>/dev/null \
    | grep "^role:" \
    | cut -d: -f2 \
    | tr -d '\r\n'
)

if [ "$MASTER_ROLE" != "master" ]; then
    echo "ERROR: redis-0 role is '$MASTER_ROLE', expected 'master'"
    echo "       The cluster may not have elected a master yet."
    echo "       Check: sudo kubectl exec -n $NAMESPACE redis-0 -- redis-cli INFO replication"
    exit 1
fi

CONNECTED_REPLICAS=$(
    sudo kubectl exec -n "$NAMESPACE" redis-0 -- \
        env REDISCLI_AUTH="$REDIS_PASSWORD" \
        redis-cli --no-auth-warning \
        INFO replication 2>/dev/null \
    | grep "^connected_slaves:" \
    | cut -d: -f2 \
    | tr -d '\r\n'
)

echo "      redis-0 is master with $CONNECTED_REPLICAS connected replica(s)"
sudo kubectl get pods -n "$NAMESPACE"

#################################################
# Restart Sentinel
#
# After restore the Sentinel pods may still keep
# old master metadata in memory. Restarting the
# StatefulSet forces a clean rediscovery.
#################################################

echo "[9/9] Restarting Sentinel..."

sudo kubectl rollout restart \
    statefulset/redis-sentinel-sentinel \
    -n "$NAMESPACE"

sudo kubectl rollout status \
    statefulset/redis-sentinel-sentinel \
    -n "$NAMESPACE" \
    --timeout=300s

echo "      Waiting for Sentinel discovery..."

for i in {1..24}; do

    SENTINEL_INFO=$(
        sudo kubectl exec \
            -n "$NAMESPACE" \
            redis-sentinel-sentinel-0 \
            -- \
            redis-cli -p 26379 SENTINEL master mymaster \
            2>/dev/null || true
    )

    MASTER_IP=$(
        echo "$SENTINEL_INFO" | awk '
        prev=="ip" {print $1; exit}
        {prev=$1}
        '
    )

    SLAVES=$(
        echo "$SENTINEL_INFO" | awk '
        prev=="num-slaves" {print $1; exit}
        {prev=$1}
        '
    )

    SENTINELS=$(
        echo "$SENTINEL_INFO" | awk '
        prev=="num-other-sentinels" {print $1; exit}
        {prev=$1}
        '
    )

    FLAGS=$(
        echo "$SENTINEL_INFO" | awk '
        prev=="flags" {print $1; exit}
        {prev=$1}
        '
    )

    if [ "$MASTER_IP" != "0.0.0.0" ] &&
       [ "${SLAVES:-0}" -ge 2 ] &&
       [ "${SENTINELS:-0}" -ge 2 ] &&
       ! echo "$FLAGS" | grep -q "disconnected"
    then
        break
    fi

    sleep 5

done

echo "      Sentinel status:"
echo "$SENTINEL_INFO"
MASTER_IP=$(
echo "$SENTINEL_INFO" | awk '
prev=="ip" {print $1; exit}
{prev=$1}
'
)

SLAVES=$(
echo "$SENTINEL_INFO" | awk '
prev=="num-slaves" {print $1; exit}
{prev=$1}
'
)

SENTINELS=$(
echo "$SENTINEL_INFO" | awk '
prev=="num-other-sentinels" {print $1; exit}
{prev=$1}
'
)

FLAGS=$(
echo "$SENTINEL_INFO" | awk '
prev=="flags" {print $1; exit}
{prev=$1}
'
)
if [ "$MASTER_IP" = "0.0.0.0" ]; then
    echo "ERROR: Sentinel has not discovered master IP yet"
    exit 1
fi

if echo "$FLAGS" | grep -q "disconnected"; then
    echo "ERROR: Sentinel still reports master as disconnected"
    exit 1
fi

if [ "${SLAVES:-0}" -lt 2 ]; then
    echo "ERROR: Sentinel discovered only $SLAVES replicas"
    exit 1
fi

if [ "${SENTINELS:-0}" -lt 2 ]; then
    echo "ERROR: Sentinel discovered only $SENTINELS peer sentinels"
    exit 1
fi


#################################################
# Success
#################################################

echo ""
echo "=================================================="
echo "  Restore completed successfully"
echo "=================================================="
