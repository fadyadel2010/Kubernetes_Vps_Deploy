#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKUP_DIR="${ROOT_DIR}/backups/restore"

NAMESPACE="postgresql"
CLUSTER_NAME="shopixy-postgres"
DATABASE_NAME="shopixy"

echo
echo "======================================================"
echo "        Shopixy PostgreSQL Restore Tool"
echo "======================================================"
echo

#########################################
# Dependencies
#########################################

for BIN in kubectl jq
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "[ERROR] Missing dependency: $BIN"
        exit 1
    fi
done

echo "[OK] Dependencies verified"

#########################################
# Backup Directory
#########################################

if [ ! -d "$BACKUP_DIR" ]
then
    echo "[ERROR] Backup directory not found:"
    echo "  $BACKUP_DIR"
    exit 1
fi

echo "[OK] Backup directory found"

#########################################
# Cluster
#########################################

STATUS=$(
kubectl get cluster "$CLUSTER_NAME" \
-n "$NAMESPACE" \
-o jsonpath='{.status.phase}'
)

if [ "$STATUS" != "Cluster in healthy state" ]
then
    echo "[ERROR] Cluster status:"
    echo "  $STATUS"
    exit 1
fi

echo "[OK] Cluster healthy"

#########################################
# Primary
#########################################

PRIMARY=$(
kubectl get cluster "$CLUSTER_NAME" \
-n "$NAMESPACE" \
-o jsonpath='{.status.currentPrimary}'
)

if [ -z "$PRIMARY" ]
then
    echo "[ERROR] Unable to detect Primary"
    exit 1
fi

echo "[OK] Primary detected:"
echo "  $PRIMARY"

#########################################
# Database
#########################################

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- psql \
-U postgres \
-lqt \
| cut -d \| -f1 \
| grep -qw "$DATABASE_NAME"

echo "[OK] Database exists:"
echo "  $DATABASE_NAME"

#########################################
# Discover Backups
#########################################

echo "======================================================"
echo "Backup Discovery"
echo "======================================================"
echo

mapfile -t BACKUPS < <(
find "$BACKUP_DIR" \
-maxdepth 1 \
-type f \
\( \
-name "*.backup" \
-o -name "*.dump" \
-o -name "*.sql" \
\) \
| sort
)

COUNT="${#BACKUPS[@]}"

if [ "$COUNT" -eq 0 ]
then
    echo "[ERROR] No backup files found."
    exit 1
fi

echo "Available Backups"
echo "-----------------"

INDEX=1

for FILE in "${BACKUPS[@]}"
do

SIZE=$(du -h "$FILE" | cut -f1)

DATE=$(date -r "$FILE" "+%Y-%m-%d %H:%M")

echo
echo "$INDEX)"
echo "File : $(basename "$FILE")"
echo "Size : $SIZE"
echo "Date : $DATE"

INDEX=$((INDEX+1))

done

echo

read -rp "Select backup number: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]
then
    echo "[ERROR] Invalid selection"
    exit 1
fi

if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$COUNT" ]
then
    echo "[ERROR] Selection out of range"
    exit 1
fi

SELECTED_BACKUP="${BACKUPS[$((CHOICE-1))]}"

#########################################
# Backup Inspection
#########################################

echo
echo "=== Backup Inspection ==="
echo

if [ ! -r "$SELECTED_BACKUP" ]; then
    echo "[ERROR] Backup is not readable"
    exit 1
fi

echo "[OK] Backup file is readable"

HEADER=$(head -c 5 "$SELECTED_BACKUP")

if [ "$HEADER" != "PGDMP" ]; then
    echo "[ERROR] Invalid PostgreSQL archive header"
    exit 1
fi

echo "[OK] Header : PGDMP"

echo
echo "Selected:"
echo "  $(basename "$SELECTED_BACKUP")"

#########################################
# Restore Target
#########################################

RESTORE_DB="shopixy_restore_test"

echo "======================================================"
echo "Restore Target"
echo "======================================================"

echo "Cluster   : $CLUSTER_NAME"
echo "Primary   : $PRIMARY"
echo "Target DB : $RESTORE_DB"

echo

#########################################
# Confirmation
#########################################

echo "======================================================"
echo "WARNING"
echo "======================================================"

echo
echo "This operation WILL:"
echo
echo "  • Create database: $RESTORE_DB"
echo "  • Restore backup into it"
echo "  • Existing database will be dropped if it exists"
echo
echo "Production database 'shopixy' WILL NOT be modified."
echo

read -rp "Type YES to continue: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo
    echo "Restore cancelled."
    exit 0
fi

echo


#########################################
# Prepare Restore Database
#########################################

echo "======================================================"
echo "Preparing Restore Database"
echo "======================================================"

echo "[INFO] Terminating active connections..."

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- psql \
-U postgres \
-d postgres \
-c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname='${RESTORE_DB}'
AND pid <> pg_backend_pid();
" >/dev/null

echo "[OK] Active connections terminated"

echo "[INFO] Dropping existing restore database..."

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- psql \
-U postgres \
-d postgres \
-c "DROP DATABASE IF EXISTS ${RESTORE_DB};"

echo "[OK] Previous restore database removed"

echo "[INFO] Creating restore database..."

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- psql \
-U postgres \
-d postgres \
-c "CREATE DATABASE ${RESTORE_DB};"

echo "[OK] Restore database created"

echo

#########################################
# Stream Backup
#########################################

echo
echo "======================================================"
echo "Stream Backup"
echo "======================================================"

TMP_DIR="/controller/restore"
TMP_BACKUP="${TMP_DIR}/$(basename "$SELECTED_BACKUP")"

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- mkdir -p "$TMP_DIR"

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- rm -f "$TMP_BACKUP" >/dev/null 2>&1 || true

echo "[INFO] Streaming backup..."

kubectl exec -i \
-n "$NAMESPACE" \
"$PRIMARY" \
-- sh -c "cat > '$TMP_BACKUP'" \
< "$SELECTED_BACKUP"

echo "[OK] Backup streamed successfully"

#########################################
# Verify Backup
#########################################

echo
echo "======================================================"
echo "Verify Backup"
echo "======================================================"

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- ls -lh "$TMP_BACKUP"

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- pg_restore --list "$TMP_BACKUP" \
>/tmp/restore.list

OBJECT_COUNT=$(wc -l < /tmp/restore.list)

TABLE_COUNT=$(grep -c " TABLE " /tmp/restore.list || true)

INDEX_COUNT=$(grep -c " INDEX " /tmp/restore.list || true)

FUNCTION_COUNT=$(grep -c " FUNCTION " /tmp/restore.list || true)

SEQUENCE_COUNT=$(grep -c " SEQUENCE " /tmp/restore.list || true)

VIEW_COUNT=$(grep -c " VIEW " /tmp/restore.list || true)

echo
echo "[OK] Objects   : $OBJECT_COUNT"
echo "[OK] Tables    : $TABLE_COUNT"
echo "[OK] Indexes   : $INDEX_COUNT"
echo "[OK] Views     : $VIEW_COUNT"
echo "[OK] Functions : $FUNCTION_COUNT"
echo "[OK] Sequences : $SEQUENCE_COUNT"

#########################################
# Restore
#########################################

echo
echo "======================================================"
echo "Restore Database"
echo "======================================================"

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- pg_restore \
--clean \
--if-exists \
--no-owner \
--no-privileges \
-U postgres \
-d "$RESTORE_DB" \
"$TMP_BACKUP"

echo
echo "[OK] Restore completed successfully"

#########################################
# Verification
#########################################

echo
echo "======================================================"
echo "Verification"
echo "======================================================"

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- psql \
-U postgres \
-d "$RESTORE_DB" \
-c "
SELECT current_database();

SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public';
"

#########################################
# Cleanup
#########################################

echo

kubectl exec \
-n "$NAMESPACE" \
"$PRIMARY" \
-- rm -f "$TMP_BACKUP"

echo "[OK] Temporary backup removed"

echo
echo "======================================================"
echo " Restore Completed Successfully"
echo "======================================================"
