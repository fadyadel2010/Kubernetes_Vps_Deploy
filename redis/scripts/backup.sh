#!/bin/bash

set -eo pipefail

#################################################
# Redis Kubernetes Backup Script
# Shopixy Infrastructure
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BACKUP_ROOT="$PROJECT_ROOT/backups/redis"
LOG_DIR="$PROJECT_ROOT/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
ARCHIVE_FILE="$BACKUP_ROOT/redis_backup_$TIMESTAMP.tar.gz"
MANIFEST_FILE="$BACKUP_ROOT/redis_backup_$TIMESTAMP.manifest"

LOG_FILE="$LOG_DIR/backup.log"

mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"

#################################################
# Load Environment Variables
#################################################

ENV_FILE="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: .env file not found"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

#################################################
# Defaults
#################################################

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_REMOTE="PostgressBackup"
BACKUP_REMOTE_PATH="${BACKUP_REMOTE_PATH:-shopixy-backups/redis}"

NAMESPACE="redis"

#################################################
# Log Rotation (by size, not line count)
#################################################

MAX_LOG_BYTES=$((5 * 1024 * 1024)) # 5 MB

if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE")
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$MAX_LOG_BYTES" "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi

#################################################
# Failure Handler
#################################################

on_exit() {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        echo "[$(date)] ERROR: Backup failed (exit code: $EXIT_CODE)" | tee -a "$LOG_FILE"
    fi
}

cleanup() {
    # kubectl cp copies files with root ownership from the pod,
    # so we need sudo to remove them
    sudo rm -rf "$BACKUP_DIR" >/dev/null 2>&1 || true
}

trap "cleanup; on_exit" EXIT

#################################################
# Logging
#################################################

echo "" | tee -a "$LOG_FILE"
echo "==================================================" | tee -a "$LOG_FILE"
echo "[$(date)] Starting Redis backup..." | tee -a "$LOG_FILE"

#################################################
# Find Replica Automatically
#################################################

REDIS_PODS=$(sudo kubectl get pods -n "$NAMESPACE" \
    -l app=redis \
    -o jsonpath='{.items[*].metadata.name}')

BACKUP_POD=""

for POD in $REDIS_PODS; do
    ROLE=$(
        sudo kubectl exec -n "$NAMESPACE" "$POD" -- \
            env REDISCLI_AUTH="$REDIS_PASSWORD" \
            redis-cli --no-auth-warning \
            INFO replication 2>/dev/null \
        | grep "^role:" \
        | cut -d: -f2 \
        | tr -d '\r\n'
    )

    if [ "$ROLE" = "slave" ]; then
        BACKUP_POD="$POD"
        break
    fi
done

if [ -z "$BACKUP_POD" ]; then
    echo "[$(date)] ERROR: No replica found" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] Selected replica: $BACKUP_POD" | tee -a "$LOG_FILE"

#################################################
# Redis Version
#################################################

REDIS_VERSION=$(
    sudo kubectl exec -n "$NAMESPACE" "$BACKUP_POD" -- \
        redis-server --version \
    | grep -oP '(?<=v=)\S+'
)

#################################################
# Trigger BGSAVE
#################################################

LASTSAVE_BEFORE=$(
    sudo kubectl exec -n "$NAMESPACE" "$BACKUP_POD" -- \
        env REDISCLI_AUTH="$REDIS_PASSWORD" \
        redis-cli --no-auth-warning \
        LASTSAVE
)

echo "[$(date)] Triggering BGSAVE..." | tee -a "$LOG_FILE"

sudo kubectl exec -n "$NAMESPACE" "$BACKUP_POD" -- \
    env REDISCLI_AUTH="$REDIS_PASSWORD" \
    redis-cli --no-auth-warning \
    BGSAVE >/dev/null

echo "[$(date)] Waiting for snapshot..." | tee -a "$LOG_FILE"

BGSAVE_DONE=0
for i in {1..60}; do
    LASTSAVE_AFTER=$(
        sudo kubectl exec -n "$NAMESPACE" "$BACKUP_POD" -- \
            env REDISCLI_AUTH="$REDIS_PASSWORD" \
            redis-cli --no-auth-warning \
            LASTSAVE
    )

    if [ "$LASTSAVE_AFTER" != "$LASTSAVE_BEFORE" ]; then
        BGSAVE_DONE=1
        break
    fi

    sleep 1
done

if [ "$BGSAVE_DONE" -eq 0 ]; then
    echo "[$(date)] ERROR: BGSAVE did not complete within 60 seconds" | tee -a "$LOG_FILE"
    exit 1
fi

#################################################
# Copy Data Directory
#################################################

echo "[$(date)] Copying Redis data..." | tee -a "$LOG_FILE"

mkdir -p "$BACKUP_DIR/data"

sudo kubectl cp \
    "$NAMESPACE/$BACKUP_POD:/data/." \
    "$BACKUP_DIR/data"

# Log what was copied so we can see what's in the backup
echo "[$(date)] Files copied from pod:" | tee -a "$LOG_FILE"
find "$BACKUP_DIR/data" -type f | while read -r f; do
    SIZE=$(wc -c < "$f")
    echo "[$(date)]   $(basename "$f") ($SIZE bytes)" | tee -a "$LOG_FILE"
done

#################################################
# Validate Backup
# An empty Redis instance produces a valid ~88-byte dump.rdb.
# We validate using RDB magic bytes, NOT file size.
#################################################

RDB_FILE="$BACKUP_DIR/data/dump.rdb"

if [ ! -f "$RDB_FILE" ]; then
    echo "[$(date)] ERROR: dump.rdb not found after kubectl cp" | tee -a "$LOG_FILE"
    exit 1
fi

RDB_SIZE=$(wc -c < "$RDB_FILE")

# Every valid RDB file begins with the ASCII string "REDIS"
RDB_MAGIC=$(head -c 5 "$RDB_FILE" 2>/dev/null || true)
if [ "$RDB_MAGIC" != "REDIS" ]; then
    echo "[$(date)] ERROR: dump.rdb failed magic byte check — file is corrupt or truly empty (0 bytes)" | tee -a "$LOG_FILE"
    echo "[$(date)]   Size: $RDB_SIZE bytes, Magic: '$RDB_MAGIC'" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] dump.rdb OK — magic bytes valid, size: $RDB_SIZE bytes" | tee -a "$LOG_FILE"

#################################################
# Compress Backup
#################################################

echo "[$(date)] Compressing backup..." | tee -a "$LOG_FILE"

tar -czf "$ARCHIVE_FILE" \
    -C "$BACKUP_DIR" .

#################################################
# Validate Archive
#################################################

tar -tzf "$ARCHIVE_FILE" >/dev/null

ARCHIVE_SIZE=$(wc -c < "$ARCHIVE_FILE")

# Only fail if the archive is impossibly small (tar itself failed silently).
# A valid archive of an empty Redis DB compresses to ~500 bytes — that is correct.
if [ "$ARCHIVE_SIZE" -lt 100 ]; then
    echo "[$(date)] ERROR: Archive is impossibly small ($ARCHIVE_SIZE bytes) — tar likely failed silently" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] Archive validated: $ARCHIVE_SIZE bytes" | tee -a "$LOG_FILE"

#################################################
# Manifest
#################################################

cat > "$MANIFEST_FILE" <<EOF
Timestamp=$TIMESTAMP
BackupPod=$BACKUP_POD
Role=slave
RedisVersion=$REDIS_VERSION
Archive=$(basename "$ARCHIVE_FILE")
ArchiveSizeBytes=$ARCHIVE_SIZE
RDBSizeBytes=$RDB_SIZE
RetentionDays=$BACKUP_RETENTION_DAYS
EOF

#################################################
# Cleanup Raw Files
#################################################

sudo rm -rf "$BACKUP_DIR"

#################################################
# Upload To Google Drive
#################################################

if command -v rclone >/dev/null 2>&1; then

    echo "[$(date)] Uploading backup to Google Drive..." | tee -a "$LOG_FILE"

    set +e
    rclone copy \
        "$ARCHIVE_FILE" \
        "$BACKUP_REMOTE:$BACKUP_REMOTE_PATH"
    RCLONE_ARCHIVE_EXIT=$?

    rclone copy \
        "$MANIFEST_FILE" \
        "$BACKUP_REMOTE:$BACKUP_REMOTE_PATH"
    RCLONE_MANIFEST_EXIT=$?
    set -e

    if [ "$RCLONE_ARCHIVE_EXIT" -ne 0 ] || [ "$RCLONE_MANIFEST_EXIT" -ne 0 ]; then
        echo "[$(date)] WARNING: Google Drive upload failed (archive: $RCLONE_ARCHIVE_EXIT, manifest: $RCLONE_MANIFEST_EXIT)" | tee -a "$LOG_FILE"
    else
        echo "[$(date)] Google Drive upload completed" | tee -a "$LOG_FILE"
    fi

else
    echo "[$(date)] WARNING: rclone not installed — skipping remote upload" | tee -a "$LOG_FILE"
fi

#################################################
# Retention
#################################################

find "$BACKUP_ROOT" \
    -type f \
    -name "*.tar.gz" \
    -mtime +"$BACKUP_RETENTION_DAYS" \
    -delete

find "$BACKUP_ROOT" \
    -type f \
    -name "*.manifest" \
    -mtime +"$BACKUP_RETENTION_DAYS" \
    -delete

#################################################
# Summary
#################################################

BACKUP_SIZE=$(du -h "$ARCHIVE_FILE" | cut -f1)

echo "[$(date)] Backup completed successfully" | tee -a "$LOG_FILE"
echo "[$(date)] Archive: $(basename "$ARCHIVE_FILE")" | tee -a "$LOG_FILE"
echo "[$(date)] Manifest: $(basename "$MANIFEST_FILE")" | tee -a "$LOG_FILE"
echo "[$(date)] Size: $BACKUP_SIZE" | tee -a "$LOG_FILE"
echo "==================================================" | tee -a "$LOG_FILE"
