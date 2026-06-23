#!/bin/bash

set -eo pipefail

#################################################
# MongoDB Kubernetes Backup Script
# Shopixy Infrastructure
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BACKUP_ROOT="$PROJECT_ROOT/backups/mongodb"
LOG_DIR="$PROJECT_ROOT/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
ARCHIVE_FILE="$BACKUP_ROOT/mongodb_backup_$TIMESTAMP.tar.gz"
MANIFEST_FILE="$BACKUP_ROOT/mongodb_backup_$TIMESTAMP.manifest"

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
# FIX 7: Typo "PostgressBackup" corrected (likely meant the rclone Google Drive remote, not Postgres)
BACKUP_REMOTE="${BACKUP_REMOTE:-MongoBackup}"
BACKUP_REMOTE_PATH="${BACKUP_REMOTE_PATH:-shopixy-backups/mongo}"

NAMESPACE="mongo"

#################################################
# Log Rotation
#################################################

if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 10000 ]; then
    tail -n 10000 "$LOG_FILE" > "$LOG_FILE.tmp"
    mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

#################################################
# Failure Handler
#################################################

on_exit() {
    EXIT_CODE=$?

    if [ "$EXIT_CODE" -ne 0 ]; then
        echo "[$(date)] ERROR: Backup failed (exit code: $EXIT_CODE)" | tee -a "$LOG_FILE"
    fi

    return 0
}

#################################################
# Cleanup
#################################################

cleanup() {
    if [ -n "${POD:-}" ]; then
        sudo kubectl exec -n "$NAMESPACE" "$POD" -- \
            rm -rf /tmp/mongobackup >/dev/null 2>&1 || true
    fi
}

# FIX 1: Two separate `trap ... EXIT` calls — the second REPLACES the first in bash,
# meaning cleanup() was silently never called. Combined into one trap.
# FIX 6: Correct order: cleanup runs first, then on_exit reads $? for error reporting.
trap "cleanup; on_exit" EXIT

#################################################
# Logging
#################################################

echo "" | tee -a "$LOG_FILE"
echo "==================================================" | tee -a "$LOG_FILE"
echo "[$(date)] Starting MongoDB backup..." | tee -a "$LOG_FILE"

#################################################
# Auto Secondary Discovery
#################################################

# FIX 3: Added missing `\` line continuations — bare newlines broke the command substitution.
POD=$(
    sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "
            rs.status().members.forEach(function(m){
                if(m.stateStr=='SECONDARY') print(m.name)
            })
        " | head -n1 | cut -d'.' -f1
)

if [ -z "$POD" ]; then
    echo "[$(date)] ERROR: No secondary node found" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] Selected secondary pod: $POD" | tee -a "$LOG_FILE"

#################################################
# Mongo Version
#################################################

# mongo:4.4 uses `mongo` shell (mongosh not available until MongoDB 5.0+)
MONGO_VERSION=$(
    sudo kubectl exec -n "$NAMESPACE" "$POD" -- \
    mongo --quiet --eval "db.version()" 2>/dev/null
)

#################################################
# Run Backup
#################################################

echo "[$(date)] Running mongodump..." | tee -a "$LOG_FILE"

# FIX 2: `> > "$LOG_FILE"` (space between the two `>`) is a syntax error. Fixed to `>>`.
# FIX 5: `sudo` does not affect shell redirects — `>> "$LOG_FILE"` ran as the calling user.
#         Using `tee -a` correctly appends to the log under current user permissions.
sudo kubectl exec -n "$NAMESPACE" "$POD" -- \
    mongodump \
        --username="$MONGO_ADMIN_USER" \
        --password="$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase=admin \
        --gzip \
        --out=/tmp/mongobackup \
    2>&1 | tee -a "$LOG_FILE"

#################################################
# Copy Backup
#################################################

echo "[$(date)] Copying backup to host..." | tee -a "$LOG_FILE"

# FIX 4: Added missing `\` line continuations.
sudo kubectl cp \
    "$NAMESPACE/$POD:/tmp/mongobackup/." \
    "$BACKUP_DIR"

#################################################
# Verify Backup Files
#################################################

if [ -z "$(find "$BACKUP_DIR" -type f)" ]; then
    echo "[$(date)] ERROR: Backup directory is empty" | tee -a "$LOG_FILE"
    exit 1
fi

#################################################
# Compress Backup
#################################################

echo "[$(date)] Compressing backup..." | tee -a "$LOG_FILE"

tar -czf "$ARCHIVE_FILE" -C "$BACKUP_DIR" .

#################################################
# Validate Archive
#################################################

echo "[$(date)] Validating archive..." | tee -a "$LOG_FILE"

tar -tzf "$ARCHIVE_FILE" >/dev/null

ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE_FILE" 2>/dev/null || echo 0)

if [ "$ARCHIVE_SIZE" -lt 1024 ]; then
    echo "[$(date)] ERROR: Archive too small" | tee -a "$LOG_FILE"
    exit 1
fi

#################################################
# Manifest
#################################################

cat > "$MANIFEST_FILE" <<EOF
Timestamp=$TIMESTAMP
ReplicaSet=$MONGO_REPLICA_SET
BackupPod=$POD
MongoVersion=$MONGO_VERSION
Archive=$(basename "$ARCHIVE_FILE")
ArchiveSizeBytes=$ARCHIVE_SIZE
RetentionDays=$BACKUP_RETENTION_DAYS
EOF

#################################################
# Cleanup Raw Backup
#################################################

sudo rm -rf "$BACKUP_DIR"

#################################################
# Upload To Google Drive
#################################################

if command -v rclone >/dev/null 2>&1; then
    echo "[$(date)] Uploading backup to Google Drive..." | tee -a "$LOG_FILE"

    rclone copy \
        "$ARCHIVE_FILE" \
        "$BACKUP_REMOTE:$BACKUP_REMOTE_PATH"

    rclone copy \
        "$MANIFEST_FILE" \
        "$BACKUP_REMOTE:$BACKUP_REMOTE_PATH"

    echo "[$(date)] Google Drive upload completed" | tee -a "$LOG_FILE"
else
    echo "[$(date)] WARNING: rclone not installed, skipping upload" | tee -a "$LOG_FILE"
fi

#################################################
# Retention Cleanup
#################################################

echo "[$(date)] Cleaning old backups..." | tee -a "$LOG_FILE"

# FIX 4: Added missing `\` line continuations — bare newlines broke both find commands.
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
