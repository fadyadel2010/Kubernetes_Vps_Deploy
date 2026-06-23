#!/bin/bash

set -e

#################################################
# Shopixy PostgreSQL Kubernetes Backup
#################################################

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BACKUP_DIR="$BASE_DIR/backups"
LOG_DIR="$BASE_DIR/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

BACKUP_FILE="$BACKUP_DIR/shopixy_backup_$TIMESTAMP.sql"

LOG_FILE="$LOG_DIR/backup.log"

mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

echo "[$(date)] Starting PostgreSQL backup..." | tee -a "$LOG_FILE"

#################################################
# Kubernetes
#################################################

export KUBECONFIG=/home/shopxy/.kube/config

#################################################
# Get Current Primary Pod
#################################################

PRIMARY=$(kubectl get cluster shopixy-postgres \
-n postgresql \
-o jsonpath='{.status.currentPrimary}')

if [ -z "$PRIMARY" ]; then

  echo "[$(date)] ERROR: Unable to determine primary node" | tee -a "$LOG_FILE"

  exit 1

fi

echo "[$(date)] Primary Node: $PRIMARY" | tee -a "$LOG_FILE"

#################################################
# Get Password
#################################################

PASSWORD=$(kubectl get secret shopixy-postgres-secret \
-n postgresql \
-o jsonpath='{.data.password}' | base64 -d)

#################################################
# pg_dump
#################################################

kubectl exec \
-n postgresql \
"$PRIMARY" \
-- bash -c "
export PGPASSWORD='$PASSWORD'
pg_dump \
-h shopixy-postgres-rw \
-U shopixy \
-d shopixy
" > "$BACKUP_FILE"

#################################################
# Validate
#################################################

if [ ! -s "$BACKUP_FILE" ]; then

  echo "[$(date)] ERROR: Backup file is empty" | tee -a "$LOG_FILE"

  exit 1

fi

#################################################
# Compress
#################################################

gzip "$BACKUP_FILE"

#################################################
# Upload
#################################################

rclone copy \
"$BACKUP_FILE.gz" \
PostgressBackup:shopixy-postgres-backups

#################################################
# Cleanup Local Files
#################################################

find "$BACKUP_DIR" \
-type f \
-name "*.gz" \
-mtime +7 \
-delete

#################################################
# Done
#################################################

SIZE=$(du -h "$BACKUP_FILE.gz" | cut -f1)

echo "[$(date)] Backup completed successfully" | tee -a "$LOG_FILE"
echo "[$(date)] Size: $SIZE" | tee -a "$LOG_FILE"

#################################################
# Backup Success Timestamp
#################################################

date +%s > "$BASE_DIR/last_success.txt"

exit 0
