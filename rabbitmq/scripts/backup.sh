#!/usr/bin/env bash

set -Eeuo pipefail

###############################################
# RabbitMQ Kubernetes Backup
# Shopixy Infrastructure
###############################################

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_ROOT="$PROJECT_ROOT/backups/rabbitmq"
LOG_DIR="$PROJECT_ROOT/logs"

LOG_FILE="$LOG_DIR/backup.log"

TMP_DIR="/tmp/rabbitmq_backup_$TIMESTAMP"

NAMESPACE="rabbitmq"

RETENTION_DAYS=7

RCLONE_REMOTE="PostgressBackup:rabbitmq"

###############################################

mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"
mkdir -p "$TMP_DIR"

###############################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" \
        | tee -a "$LOG_FILE"
}

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

###############################################

log "========================================="
log "RabbitMQ Backup Started"
log "Timestamp: $TIMESTAMP"
log "========================================="

###############################################
# Verify Cluster
###############################################

PODS=$(sudo kubectl get pods \
    -n "$NAMESPACE" \
    -l app.kubernetes.io/name=rabbitmq \
    --no-headers 2>/dev/null | wc -l)

if [ "$PODS" -eq 0 ]; then
    log "ERROR: No RabbitMQ pods found"
    exit 1
fi

log "Detected $PODS RabbitMQ nodes"

###############################################
# Export Definitions
###############################################

log "Exporting RabbitMQ definitions"

USERNAME=$(sudo kubectl get secret rabbitmq-default-user \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' | base64 -d)

PASSWORD=$(sudo kubectl get secret rabbitmq-default-user \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 -d)

# Stream stdout directly to a local file — avoids writing to the pod filesystem.
sudo kubectl exec \
    -n "$NAMESPACE" \
    rabbitmq-server-0 \
    -- rabbitmqadmin \
    --username="$USERNAME" \
    --password="$PASSWORD" \
    definitions export \
    > "$TMP_DIR/definitions.json"

# FIX 2: Validate that the definitions file was actually written and is non-empty.
if [ ! -s "$TMP_DIR/definitions.json" ]; then
    log "ERROR: definitions.json is missing or empty after export"
    exit 1
fi

log "Definitions exported"

###############################################
# Cluster Info
###############################################

log "Collecting cluster information"

{
    echo "RabbitMQ Backup"
    echo "==========================="
    echo
    echo "Timestamp:"
    echo "$TIMESTAMP"
    echo

    echo "RabbitMQ Version:"
    sudo kubectl exec -n "$NAMESPACE" rabbitmq-server-0 -- rabbitmqctl version

    echo
    echo "Cluster Status:"
    sudo kubectl exec -n "$NAMESPACE" rabbitmq-server-0 -- rabbitmqctl cluster_status

} > "$TMP_DIR/cluster-info.txt"

###############################################
# Manifest
###############################################

# FIX 4: Use "head -1" instead of "tail -1" to reliably capture the version
#         string; "tail -1" can grab a trailing blank line depending on the
#         rabbitmqctl output format.
VERSION=$(sudo kubectl exec \
    -n "$NAMESPACE" \
    rabbitmq-server-0 \
    -- rabbitmqctl version | head -1)

cat > "$TMP_DIR/manifest.json" <<EOF
{
  "type": "rabbitmq",
  "cluster": "rabbitmq",
  "namespace": "$NAMESPACE",
  "nodes": $PODS,
  "version": "$VERSION",
  "timestamp": "$TIMESTAMP"
}
EOF

###############################################
# Backup Node Data
###############################################

# FIX 5: Derive the node range dynamically from $PODS instead of hardcoding
#         "0 1 2". The original loop would silently skip nodes when PODS < 3,
#         or fail to back up nodes beyond index 2 when PODS > 3.
for NODE in $(seq 0 $(( PODS - 1 )))
do

    POD="rabbitmq-server-$NODE"

    log "Backing up $POD"

    # Stream tar output directly to a local file — avoids writing to the pod filesystem.
    if ! sudo kubectl exec \
        -n "$NAMESPACE" \
        "$POD" \
        -- tar czf - /var/lib/rabbitmq \
        > "$TMP_DIR/$POD.tar.gz"; then
        log "ERROR: tar stream failed for $POD"
        exit 1
    fi

    log "$POD completed"

done

###############################################
# Create Final Archive
###############################################

ARCHIVE_NAME="rabbitmq_backup_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="$BACKUP_ROOT/$ARCHIVE_NAME"

log "Creating archive"

tar -czf \
    "$ARCHIVE_PATH" \
    -C "$TMP_DIR" .

###############################################
# Upload To Google Drive
###############################################

if command -v rclone >/dev/null 2>&1
then

    log "Uploading archive to Google Drive"

    # FIX 7: Log an error and exit non-zero if the rclone upload fails.
    #         Previously a silent failure would leave the backup un-uploaded
    #         with no indication in the log.
    if ! rclone copy \
        "$ARCHIVE_PATH" \
        "$RCLONE_REMOTE"; then
        log "ERROR: rclone upload to Google Drive failed"
        exit 1
    fi

    log "Google Drive upload completed"

fi

###############################################
# Retention
###############################################

log "Cleaning old backups"

find "$BACKUP_ROOT" \
    -type f \
    -name "*.tar.gz" \
    -mtime +"$RETENTION_DAYS" \
    -delete

###############################################
# Summary
###############################################

SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)

log "========================================="
log "Backup completed successfully"
log "Archive: $ARCHIVE_NAME"
log "Size: $SIZE"
log "========================================="
