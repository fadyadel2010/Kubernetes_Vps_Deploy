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
echo " Firewall Validation Completed"
echo "========================================="
