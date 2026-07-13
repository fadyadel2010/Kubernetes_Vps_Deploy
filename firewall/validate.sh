#!/usr/bin/env bash
set -euo pipefail
EXPECTED_PORTS=(
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
echo
echo "========================================="
echo " Shopixy Firewall Validation"
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

echo "[OK] Dependencies"
echo
###############################################
# UFW Enabled
###############################################
STATUS=$(sudo ufw status | head -1)
echo "$STATUS" | grep -q "Status: active" || {
    echo "[ERROR] UFW is not active"
    exit 1
}
echo "[OK] UFW Active"
###############################################
# Default Policy
###############################################
echo
echo "---------------"
echo "UFW Status"
echo "---------------"

sudo ufw status verbose

sudo ufw status verbose | grep -q "Default: deny (incoming)" || {
    echo "[ERROR] Incoming policy is not DENY"
    exit 1
}
echo "[OK] Default Incoming Policy"
###############################################
# Rules
###############################################
for PORT in "${EXPECTED_PORTS[@]}"
do
   sudo ufw status numbered | grep -q "${PORT}/tcp" || {
        echo "[ERROR] Missing Rule ${PORT}"
        exit 1
    }
    echo "[OK] ${PORT}/tcp"
done
###############################################
# Kubernetes
###############################################

echo
echo "---------------"
echo "Kubernetes"
echo "---------------"

sudo kubectl get nodes >/dev/null

echo "[OK] Kubernetes API"

sudo kubectl get pods -A >/dev/null

echo "[OK] Pods"

sudo kubectl get svc -A >/dev/null

echo "[OK] Services"

sudo kubectl get ingress -A >/dev/null

echo "[OK] Ingress"
###############################################
# Listening Ports
###############################################

echo
echo "---------------"
echo "Port Listening Check"
echo "---------------"

for PORT in "${EXPECTED_PORTS[@]}"
do
    sudo ss -tln | grep -q ":${PORT} " \
    && echo "[OK] Port ${PORT} listening" \
    || echo "[WARN] Port ${PORT} not listening"
done
###############################################
# Summary
###############################################
echo
echo "---------------"
echo "UFW Rules"
echo "---------------"
sudo ufw status numbered
echo
echo "---------------"
echo "Listening Ports"
echo "---------------"
sudo ss -tulpn
echo
echo "========================================="
echo " Validation Summary"
echo "========================================="

echo "[OK] UFW Active"
echo "[OK] Policies"
echo "[OK] Rules"
echo "[OK] Kubernetes"
echo "[OK] Services"

echo
echo "========================================="
echo " Firewall Validation Completed Successfully"
echo "========================================="
