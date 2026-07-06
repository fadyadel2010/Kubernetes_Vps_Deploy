#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "========================================="
echo " Shopixy Firewall Bootstrap"
echo "========================================="
echo


###############################################
# Dependencies
###############################################

for BIN in sudo ufw ss
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "[ERROR] Missing dependency: $BIN"
        exit 1
    fi
done

###############################################
# Install UFW (if needed)
###############################################

if ! dpkg -s sudo ufw >/dev/null 2>&1
then
    echo "[INFO] Installing UFW..."
   sudo apt-get update
    sudo apt-get install -y ufw
fi

###############################################
# Reset
###############################################

echo "[INFO] Resetting Firewall..."

sudo ufw --force reset

###############################################
# Default Policies
###############################################

sudo ufw default deny incoming
sudo ufw default allow outgoing

###############################################
# Allow Rules
###############################################

ALLOW_PORTS=(
22
80
443
6443
5432
27017
6379
5672
15672
9200
9000
)

for PORT in "${ALLOW_PORTS[@]}"
do
    sudo ufw allow "${PORT}/tcp"
done

###############################################
# Enable
###############################################

sudo ufw --force enable

###############################################
# Validation
###############################################

echo
sudo ufw status numbered

echo
echo "========================================="
echo " Firewall Bootstrap Completed"
echo "========================================="
echo

