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
for BIN in sudo ufw ss kubectl
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
if ! dpkg -s ufw >/dev/null 2>&1
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
sudo ufw logging low
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

echo
echo "[INFO] Waiting for firewall to become active..."

sleep 3

###############################################
# Validate UFW
###############################################

echo
echo "[INFO] Validating UFW..."

sudo ufw status verbose

echo

###############################################
# Validate Kubernetes
###############################################

echo "[INFO] Validating Kubernetes API..."

sudo kubectl get nodes

echo
echo "[INFO] Validating System Pods..."

sudo kubectl get pods -A >/dev/null

echo "[OK] Kubernetes reachable."
echo

###############################################
# Validate Services
###############################################

echo "[INFO] Checking services..."

sudo kubectl get svc -A >/dev/null

echo "[OK] Services reachable."
echo

###############################################
# Validate Ingress
###############################################

echo "[INFO] Checking ingress..."

sudo kubectl get ingress -A >/dev/null

echo "[OK] Ingress reachable."
echo

###############################################
# Validate Kubernetes API Health
###############################################

echo "[INFO] Checking Kubernetes API health..."

sudo kubectl cluster-info >/dev/null


echo "[OK] Kubernetes API healthy."
echo

###############################################
# Validation
###############################################
echo
echo "========================================="
echo " Firewall Status"
echo "========================================="

sudo ufw status numbered

echo
sudo ufw status verbose

echo
echo "========================================="
echo " Listening Ports"
echo "========================================="

sudo ss -tln

echo
echo "========================================="
echo " Firewall Bootstrap Completed"
echo "========================================="
echo
