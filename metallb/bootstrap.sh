#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

echo "========================================="
echo " Shopixy MetalLB Bootstrap"
echo "========================================="

###############################################
# Required Tools
###############################################

for BIN in kubectl
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "[ERROR] Missing dependency: $BIN"
        exit 1
    fi
done

###############################################
# Required Files
###############################################

for FILE in ipaddresspool.yaml l2advertisement.yaml
do
    if [ ! -f "$SCRIPT_DIR/$FILE" ]
    then
        echo "[ERROR] Missing file: $FILE"
        exit 1
    fi
done

###############################################
# Install MetalLB
###############################################

if ! $KUBECTL get namespace metallb-system >/dev/null 2>&1
then

    echo "Installing MetalLB..."

    $KUBECTL apply -f \
https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml

else

    echo "MetalLB already installed"

fi

###############################################
# Wait Controller
###############################################

echo
echo "Waiting for MetalLB Controller..."

$KUBECTL rollout status deployment/controller \
    -n metallb-system \
    --timeout=180s

###############################################
# Wait Speaker
###############################################

echo
echo "Waiting for MetalLB Speaker..."

$KUBECTL rollout status daemonset/speaker \
    -n metallb-system \
    --timeout=180s

###############################################
# Apply Configuration
###############################################

echo
echo "Applying IPAddressPool..."

$KUBECTL apply -f "$SCRIPT_DIR/ipaddresspool.yaml"

echo
echo "Applying L2Advertisement..."

$KUBECTL apply -f "$SCRIPT_DIR/l2advertisement.yaml"

###############################################
# Verify
###############################################

$KUBECTL get ipaddresspool -n metallb-system >/dev/null
echo "[OK] IPAddressPool"

$KUBECTL get l2advertisement -n metallb-system >/dev/null
echo "[OK] L2Advertisement"

CONTROLLER=$(
$KUBECTL get deployment controller \
    -n metallb-system \
    -o jsonpath='{.status.availableReplicas}'
)

[ "${CONTROLLER:-0}" -ge 1 ] || {
    echo "[ERROR] MetalLB Controller not available"
    exit 1
}

SPEAKER_READY=$(
$KUBECTL get daemonset speaker \
    -n metallb-system \
    -o jsonpath='{.status.numberReady}'
)

SPEAKER_DESIRED=$(
$KUBECTL get daemonset speaker \
    -n metallb-system \
    -o jsonpath='{.status.desiredNumberScheduled}'
)

[ "$SPEAKER_READY" = "$SPEAKER_DESIRED" ] || {
    echo "[ERROR] MetalLB Speaker not fully ready"
    exit 1
}

echo "[OK] MetalLB Controller"
echo "[OK] MetalLB Speaker"

echo
echo "========================================="
echo " MetalLB Bootstrap Completed Successfully"
echo "========================================="
echo
