#!/usr/bin/env bash

set -Eeuo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

echo
echo "========================================="
echo " Traefik Validation"
echo "========================================="
echo

###############################################
# Namespace
###############################################

$KUBECTL get namespace kube-system >/dev/null

echo "[OK] Namespace"

###############################################
# Deployment
###############################################

AVAILABLE=$(
$KUBECTL get deployment traefik \
    -n kube-system \
    -o jsonpath='{.status.availableReplicas}'
)

[ "${AVAILABLE:-0}" -ge 1 ] || {
    echo "[ERROR] Traefik Deployment not available"
    exit 1
}

echo "[OK] Deployment"

###############################################
# Pods Ready
###############################################

$KUBECTL wait \
    --for=condition=Ready \
    pod \
    -l app.kubernetes.io/name=traefik \
    -n kube-system \
    --timeout=120s >/dev/null

echo "[OK] Pods Ready"

###############################################
# Service
###############################################

$KUBECTL get svc traefik -n kube-system >/dev/null

echo "[OK] Service"

###############################################
# External IP
###############################################

IP=$(
$KUBECTL get svc traefik \
    -n kube-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
)

[ -n "${IP:-}" ] || {
    echo "[ERROR] External IP not assigned"
    exit 1
}

echo "[OK] External IP : $IP"

###############################################
# IngressClass
###############################################

$KUBECTL get ingressclass traefik >/dev/null

echo "[OK] IngressClass"

###############################################
# TCP Ports
###############################################

PORTS=$(
$KUBECTL get svc traefik \
    -n kube-system \
    -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}'
)

for PORT in 80 443 5432 5672 6379 9000 9200
do
    if [[ "$PORTS" != *"$PORT"* ]]
    then
        echo "[ERROR] Missing Port $PORT"
        exit 1
    fi

    echo "[OK] Port $PORT"

done

###############################################
# Summary
###############################################

echo
$KUBECTL get pods -n kube-system -l app.kubernetes.io/name=traefik

echo
echo "========================================="
echo " Traefik Validation Completed"
echo "========================================="
echo
