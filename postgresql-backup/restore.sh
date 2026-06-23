#!/bin/bash
set -eo pipefail

#################################################
# PostgreSQL Restore Script
# Shopixy Kubernetes Infrastructure
#################################################

if [ $# -eq 0 ]; then
  echo "Usage:"
  echo "  ./restore.sh <backup_file>"
  exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file not found:"
  echo "  $BACKUP_FILE"
  exit 1
fi

export KUBECONFIG=~/.kube/config

RESTORE_DB="shopixy_restore_test"

echo "======================================="
echo "Shopixy PostgreSQL Restore Test"
echo "======================================="
echo ""
echo "Backup File:      $BACKUP_FILE"
echo "Restore Database: $RESTORE_DB"
echo ""

#################################################
# Find Current Primary
#################################################

PRIMARY=$(kubectl get cluster shopixy-postgres -n postgresql -o jsonpath='{.status.currentPrimary}')
echo "Primary Node: $PRIMARY"

#################################################
# Recreate Restore Database
#################################################

echo ""
echo "Dropping existing restore database..."
kubectl exec -n postgresql "$PRIMARY" -- psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $RESTORE_DB;"

echo "Creating restore database..."
kubectl exec -n postgresql "$PRIMARY" -- psql -U postgres -d postgres -c "CREATE DATABASE $RESTORE_DB;"

#################################################
# Restore Backup
#################################################

echo ""
echo "Restoring backup..."

if [[ "$BACKUP_FILE" == *.gz ]]; then
  gunzip -c "$BACKUP_FILE" | \
    kubectl exec -i \
      -n postgresql \
      "$PRIMARY" \
      -- psql \
      -U postgres \
      -d "$RESTORE_DB"
else
  cat "$BACKUP_FILE" | \
    kubectl exec -i \
      -n postgresql \
      "$PRIMARY" \
      -- psql \
      -U postgres \
      -d "$RESTORE_DB"
fi

#################################################
# Validation
#################################################

echo ""
echo "Restore completed successfully."
echo ""

kubectl exec -n postgresql "$PRIMARY" -- psql -U postgres -d "$RESTORE_DB" -c '\dt'

echo ""
echo "======================================="
echo "Restore test finished successfully."
echo "======================================="
echo ""
