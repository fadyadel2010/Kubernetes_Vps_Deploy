#!/bin/bash
set -e
#################################################
# Shopixy PostgreSQL Kubernetes Backup
#################################################
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$BASE_DIR/backups"
LOG_DIR="$BASE_DIR/logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="$BACKUP_DIR/shopixy_backup_$TIMESTAMP.backup"
LOG_FILE="$LOG_DIR/backup.log"
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

START=$(date +%s)
echo "[$(date)] Starting PostgreSQL backup..." | tee -a "$LOG_FILE"

#################################################
# Kubernetes (K3s)
#################################################
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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
# pg_dump (custom format, matches restore.sh expectations)
#################################################
kubectl exec \
-n postgresql \
"$PRIMARY" \
-- bash -c "
export PGPASSWORD='$PASSWORD'
pg_dump \
-Fc \
-h shopixy-postgres-rw \
-U shopixy \
-d shopixy
" > "$BACKUP_FILE"

#################################################
# Validate dump
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
# Validate compressed file
#################################################
if [ ! -s "$BACKUP_FILE.gz" ]; then
  echo "[$(date)] ERROR: Compressed backup file is empty or missing" | tee -a "$LOG_FILE"
  exit 1
fi

#################################################
# Upload
#################################################
# NOTE: confirm this rclone remote name matches "rclone listremotes" exactly
# (double-check the extra "s": PostgressBackup vs PostgresBackup)
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
END=$(date +%s)
echo "[$(date)] Backup completed successfully" | tee -a "$LOG_FILE"
echo "[$(date)] Size: $SIZE" | tee -a "$LOG_FILE"
echo "[$(date)] Duration: $((END-START)) sec" | tee -a "$LOG_FILE"

#################################################
# Backup Success Timestamp
#################################################
date +%s > "$BASE_DIR/last_success.txt"
exit 0
