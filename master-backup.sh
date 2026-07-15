#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "========================================="
echo "      Shopixy Master Backup"
echo "========================================="
echo

############################################
# rclone
############################################

if ! command -v rclone >/dev/null 2>&1
then

    echo "[INFO] Installing rclone..."

    curl https://rclone.org/install.sh | sudo bash

    echo "[OK] rclone installed"

else

    echo "[SKIP] rclone already installed"

fi

if ! command -v rclone >/dev/null 2>&1
then

    echo "[ERROR] Failed to install rclone"

    exit 1

fi

############################################
# Google Drive
############################################

if ! rclone listremotes | grep -q "^PostgressBackup:$"
then

    echo
    echo "[ERROR] Google Drive remote is not configured."
    echo
    echo "Run:"
    echo
    echo "    rclone config"
    echo

    exit 1

fi

echo "[OK] Google Drive configured"
echo

############################################
# PostgreSQL
############################################

echo "[1/2] PostgreSQL Backup"

bash "$ROOT_DIR/postgresql-backup/backup.sh"

echo

############################################
# MongoDB
############################################

echo "[2/2] MongoDB Backup"

bash "$ROOT_DIR/mongo-native/scripts/backup.sh"

echo

############################################
# Cleanup Local
############################################

echo "[INFO] Cleaning local backups..."

find "$ROOT_DIR/postgresql-backup/backups" \
-type f \
-mtime +15 \
-delete

find "$ROOT_DIR/mongo-native/backups" \
-type f \
-mtime +15 \
-delete

echo "[OK]"
echo

############################################
# Cleanup Google Drive
############################################

echo "[INFO] Cleaning Google Drive backups..."

rclone delete \
PostgressBackup:shopixy-postgres-backups \
--min-age 15d \
>/dev/null 2>&1 || true

rclone delete \
PostgressBackup:shopixy-mongodb-backups \
--min-age 15d \
>/dev/null 2>&1 || true

rclone rmdirs \
PostgressBackup:shopixy-postgres-backups \
>/dev/null 2>&1 || true

rclone rmdirs \
PostgressBackup:shopixy-mongodb-backups \
>/dev/null 2>&1 || true

echo "[OK]"
echo

echo "========================================="
echo " Master Backup Completed Successfully"
echo "========================================="
echo

############################################
# Install Timer
############################################

if systemctl list-unit-files | grep -q "^shopixy-backup.timer"
then

    echo "[SKIP] Backup timer already installed"

else

    echo "[INFO] Installing backup timer..."

    sudo cp \
        "$ROOT_DIR/shopixy-backup.service" \
        /etc/systemd/system/

    sudo cp \
        "$ROOT_DIR/shopixy-backup.timer" \
        /etc/systemd/system/

    sudo systemctl daemon-reload

    sudo systemctl enable shopixy-backup.timer

    sudo systemctl start shopixy-backup.timer

    echo "[OK] Backup timer installed"

fi

systemctl list-timers shopixy-backup.timer --no-pager
