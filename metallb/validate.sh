#!/usr/bin/env bash

set -Eeuo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

echo
echo "========================================="
echo " MetalLB Validation"
echo "========================================="
echo

###############################################
# Namespace
###############################################

$KUBECTL get namespace metallb-system >/dev/null

echo "[OK] Namespace"

###############################################
# Controller
###############################################

AVAILABLE=$(
$KUBECTL get deployment controller \
    -n metallb-system \
    -o jsonpath='{.status.availableReplicas}'
)

[ "${AVAILABLE:-0}" -ge 1 ] || {
    echo "[ERROR] Controller not available"
    exit 1
}

echo "[OK] Controller"

###############################################
# Speaker
###############################################

READY=$(
$KUBECTL get daemonset speaker \
    -n metallb-system \
    -o jsonpath='{.status.numberReady}'
)

DESIRED=$(
$KUBECTL get daemonset speaker \
    -n metallb-system \
    -o jsonpath='{.status.desiredNumberScheduled}'
)

[ "$READY" = "$DESIRED" ] || {
    echo "[ERROR] Speaker not ready"
    exit 1
}

echo "[OK] Speaker"

###############################################
# IPAddressPool
###############################################

$KUBECTL get ipaddresspool -n metallb-system >/dev/null

echo "[OK] IPAddressPool"

###############################################
# L2Advertisement
###############################################

$KUBECTL get l2advertisement -n metallb-system >/dev/null

echo "[OK] L2Advertisement"

###############################################
# Traefik External IP
###############################################

IP=$(
$KUBECTL get svc traefik \
    -n kube-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
)

if [ -z "${IP:-}" ]
then
    echo "[ERROR] Traefik has no External IP"
    exit 1
fi

echo "[OK] Traefik External IP : $IP"

###############################################
# Summary
###############################################

echo
$KUBECTL get pods -n metallb-system

echo
echo "========================================="
echo " MetalLB Validation Completed"
echo "========================================="
echo
