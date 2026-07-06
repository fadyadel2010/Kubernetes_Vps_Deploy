#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

echo
echo "======================================================"
echo "     Network Policies Validation"
echo "======================================================"
echo

##################################################
# Dependencies
##################################################

for BIN in kubectl
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "[ERROR] Missing dependency: $BIN"
        exit 1
    fi
done

##################################################
# Default Deny Validation
##################################################

echo "=== Default Deny Policies ==="

for NS in \
    monitoring \
    prometheus \
    postgresql \
    redis \
    rabbitmq \
    mongo \
    minio \
    opensearch
do
    $KUBECTL get networkpolicy default-deny \
        -n "$NS" >/dev/null || {
        echo "[ERROR] Missing default-deny in namespace: $NS"
        exit 1
    }

    echo "[OK] $NS"
done

##################################################
# Service Policies
##################################################

echo
echo "=== Service Policies ==="

declare -A POLICIES=(
    [monitoring]="grafana"
    [prometheus]="prometheus"
    [postgresql]="postgresql"
    [redis]="redis"
    [rabbitmq]="rabbitmq"
    [mongo]="mongo"
    [minio]="minio"
    [opensearch]="opensearch"
)

for NS in "${!POLICIES[@]}"
do
    POLICY="${POLICIES[$NS]}"

    $KUBECTL get networkpolicy "$POLICY" \
        -n "$NS" >/dev/null || {
        echo "[ERROR] Missing policy '$POLICY' in namespace '$NS'"
        exit 1
    }

    echo "[OK] $POLICY"
done

##################################################
# Traefik
##################################################

echo
echo "=== Traefik Policy ==="

$KUBECTL get networkpolicy traefik-ingress \
    -n kube-system >/dev/null || {
    echo "[ERROR] Missing Traefik NetworkPolicy"
    exit 1
}

echo "[OK] Traefik Ingress Policy"

##################################################
# Summary
##################################################

echo
echo "=== Installed Network Policies ==="

$KUBECTL get networkpolicy -A

echo
echo "======================================================"
echo " Network Policies Validation Completed Successfully"
echo "======================================================"
echo
