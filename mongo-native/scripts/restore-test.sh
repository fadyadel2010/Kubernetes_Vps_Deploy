#!/bin/bash

set -eo pipefail

#################################################
# MongoDB Restore Validation Script
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/restore-test.log"

mkdir -p "$LOG_DIR"

#################################################
# Load Environment Variables
#################################################

ENV_FILE="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

#################################################
# Input Validation
#################################################

if [ -z "$1" ]; then
    echo "Usage:"
    echo "./scripts/restore-test.sh <backup.tar.gz>"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found"
    exit 1
fi

#################################################
# Settings
#################################################

NAMESPACE="mongo"
PRIMARY_POD="mongo-1"

RESTORE_DB="shopixy_restore_test"

RESTORE_DIR="/tmp/mongo_restore_$$"

mkdir -p "$RESTORE_DIR"

cleanup() {
    rm -rf "$RESTORE_DIR"
}

trap cleanup EXIT

#################################################
# Start
#################################################

echo "[$(date)] Starting restore validation..." | tee -a "$LOG_FILE"

#################################################
# Validate Archive
#################################################

tar -tzf "$BACKUP_FILE" >/dev/null

#################################################
# Extract Archive
#################################################

echo "[$(date)] Extracting archive..." | tee -a "$LOG_FILE"

tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"


#################################################
# Copy To Pod
#################################################

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
rm -rf /tmp/mongorestore

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
mkdir -p /tmp/mongorestore

sudo kubectl cp \
"$RESTORE_DIR/." \
"$NAMESPACE/$PRIMARY_POD:/tmp/mongorestore"

#################################################
# Drop Existing Test Database
#################################################

echo "[$(date)] Dropping old restore database..." | tee -a "$LOG_FILE"

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
mongo "$RESTORE_DB" \
-u "$MONGO_ADMIN_USER" \
-p "$MONGO_ADMIN_PASSWORD" \
--authenticationDatabase admin \
--quiet \
--eval "db.dropDatabase()"

#################################################
# Restore
#################################################

echo "[$(date)] Running mongorestore..." | tee -a "$LOG_FILE"

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
mongorestore \
  --username="$MONGO_ADMIN_USER" \
  --password="$MONGO_ADMIN_PASSWORD" \
  --authenticationDatabase=admin \
  --gzip \
  --drop \
  --nsFrom="shopixy.*" \
  --nsTo="$RESTORE_DB.*" \
  /tmp/mongorestore

#################################################
# Verify
#################################################

echo "[$(date)] Verifying restore..." | tee -a "$LOG_FILE"

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
mongo "$RESTORE_DB" \
-u "$MONGO_ADMIN_USER" \
-p "$MONGO_ADMIN_PASSWORD" \
--authenticationDatabase admin \
--quiet \
--eval '
print("products=" + db.products.find().count());
print("orders=" + db.orders.find().count());
'

#################################################
# Cleanup Pod
#################################################

sudo kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
rm -rf /tmp/mongorestore >/dev/null 2>&1 || true

#################################################
# Done
#################################################

echo "[$(date)] Restore validation completed" | tee -a "$LOG_FILE"
