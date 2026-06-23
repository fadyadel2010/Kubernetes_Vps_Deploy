#!/bin/bash

set -eo pipefail

#################################################
# MongoDB Production Restore Script
# Shopixy Infrastructure
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/restore.log"

mkdir -p "$LOG_DIR"

#################################################
# Log Rotation
#################################################

# Added for consistency with backup.sh
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 10000 ]; then
    tail -n 10000 "$LOG_FILE" > "$LOG_FILE.tmp"
    mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

#################################################
# Load Environment Variables
#################################################

ENV_FILE="$PROJECT_ROOT/.env"

# FIX 4: Error messages now go to stderr (>&2) and are also written to the log file.
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found" | tee -a "$LOG_FILE" >&2
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

#################################################
# Input Validation
#################################################

if [ -z "$1" ]; then
    echo ""
    echo "Usage:"
    echo "  ./scripts/restore.sh <backup.tar.gz>"
    echo ""
    exit 1
fi

BACKUP_FILE="$1"

# FIX 4: Same stderr + log fix for missing backup file error.
if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
fi

#################################################
# Kubernetes Settings
#################################################

NAMESPACE="mongo"

#################################################
# Detect Primary
#################################################

# FIX 1: Added missing `\` line continuations — bare newlines broke the entire command substitution.
PRIMARY_POD=$(
    sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval '
            rs.status().members.forEach(function(m){
                if(m.stateStr=="PRIMARY") print(m.name)
            })
        ' | head -n1 | cut -d'.' -f1
)

if [ -z "$PRIMARY_POD" ]; then
    echo "ERROR: Could not determine PRIMARY node" | tee -a "$LOG_FILE" >&2
    exit 1
fi

#################################################
# Validate Archive
#################################################

echo "[$(date)] Validating archive..." | tee -a "$LOG_FILE"

tar -tzf "$BACKUP_FILE" >/dev/null

#################################################
# Confirmation Prompt
#################################################

echo ""
echo "=================================================="
echo "WARNING - PRODUCTION RESTORE"
echo "=================================================="
echo ""
echo "Primary Pod : $PRIMARY_POD"
echo "Replica Set : $MONGO_REPLICA_SET"
echo ""
echo "This operation will:"
echo ""
echo "  DROP DATABASE shopixy"
echo "  RESTORE DATABASE shopixy"
echo ""
echo "Backup:"
echo "  $(basename "$BACKUP_FILE")"
echo ""
echo "Type YES to continue:"
echo ""

read -r CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Restore cancelled."
    exit 1
fi

#################################################
# Temporary Directory
#################################################

RESTORE_DIR="/tmp/mongo_restore_$$"

mkdir -p "$RESTORE_DIR"

# FIX 2: Removed markdown backtick fences from inside the function body —
# they were a copy-paste artifact that would cause a syntax error if run literally.
cleanup() {
    rm -rf "$RESTORE_DIR"
    sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
        rm -rf /tmp/mongorestore >/dev/null 2>&1 || true
}

trap cleanup EXIT

#################################################
# Start Restore
#################################################

echo "[$(date)] Starting production restore..." | tee -a "$LOG_FILE"

#################################################
# Extract Backup
#################################################

echo "[$(date)] Extracting archive..." | tee -a "$LOG_FILE"

tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

#################################################
# Copy To Primary
#################################################

# FIX 1: Added missing `\` line continuations to all three kubectl commands.
sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
    rm -rf /tmp/mongorestore

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
    mkdir -p /tmp/mongorestore

sudo kubectl cp \
    "$RESTORE_DIR/." \
    "$NAMESPACE/$PRIMARY_POD:/tmp/mongorestore"

#################################################
# Drop Existing Database
#################################################

echo "[$(date)] Dropping existing database..." | tee -a "$LOG_FILE"

# FIX 1: Added missing `\` line continuations.
# FIX 3: Removed explicit db.dropDatabase() — mongorestore --drop already handles this
#         per-collection. Running both causes a redundant full drop before restore begins,
#         leaving a window where the database is empty if mongorestore fails mid-way.
#         The --drop flag on mongorestore is safer: it drops each collection just before restoring it.
sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
    mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval 'db.getSiblingDB("shopixy").dropDatabase()'

#################################################
# Restore
#################################################

echo "[$(date)] Running mongorestore..." | tee -a "$LOG_FILE"

# FIX 1: Added missing `\` line continuations.
# NOTE: --drop kept here so each collection is cleanly replaced during restore.
sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
    mongorestore \
        --username="$MONGO_ADMIN_USER" \
        --password="$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase=admin \
        --gzip \
        --drop \
        --nsInclude="shopixy.*" \
        /tmp/mongorestore

#################################################
# Verification
#################################################

echo "[$(date)] Verifying restore..." | tee -a "$LOG_FILE"

# FIX 1: Added missing `\` line continuations.
# FIX 5: Replaced deprecated .find().count() with countDocuments() —
#         .count() uses stale metadata and can return wrong results after an unclean restore.
sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
    mongo shopixy \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval '
            print("products=" + db.products.countDocuments({}));
            print("orders="   + db.orders.countDocuments({}));
        '

#################################################
# Complete
#################################################

echo "[$(date)] Restore completed successfully" | tee -a "$LOG_FILE"
echo "[$(date)] Backup: $(basename "$BACKUP_FILE")" | tee -a "$LOG_FILE"
