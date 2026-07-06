#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

echo
echo "======================================================"
echo "     Shopixy Prometheus Validation"
echo "======================================================"
echo

##################################################
# Required Binaries
##################################################

for BIN in kubectl
do
  if ! command -v "$BIN" >/dev/null 2>&1
  then
    echo
    echo "[ERROR] Missing dependency: $BIN"
    echo
    exit 1
  fi
done

echo "[OK] Dependencies verified"

##################################################
# Operator
##################################################

echo
echo "=== Prometheus Operator ==="

$KUBECTL rollout status \
deployment/prometheus-kube-prometheus-operator \
-n prometheus \
--timeout=300s

echo "[OK] Operator healthy"

##################################################
# Prometheus
##################################################

echo
echo "=== Prometheus ==="

$KUBECTL rollout status \
statefulset/prometheus-prometheus-kube-prometheus-prometheus \
-n prometheus \
--timeout=600s

echo "[OK] Prometheus StatefulSet healthy"

##################################################
# kube-state-metrics
##################################################

echo
echo "=== kube-state-metrics ==="

$KUBECTL rollout status \
deployment/prometheus-kube-state-metrics \
-n prometheus \
--timeout=300s

echo "[OK] kube-state-metrics healthy"

##################################################
# Node Exporter
##################################################

echo
echo "=== node-exporter ==="

$KUBECTL rollout status \
daemonset/prometheus-prometheus-node-exporter \
-n prometheus \
--timeout=300s

echo "[OK] node-exporter healthy"

##################################################
# Service
##################################################

echo
echo "=== Service ==="

$KUBECTL get svc \
prometheus-kube-prometheus-prometheus \
-n prometheus >/dev/null

echo "[OK] Service verified"

##################################################
# Ingress
##################################################

echo
echo "=== Ingress ==="

$KUBECTL get ingress \
prometheus \
-n prometheus >/dev/null

echo "[OK] Ingress verified"

##################################################
# Pods Summary
##################################################

echo
echo "=== Pods ==="

$KUBECTL get pods -n prometheus

##################################################
# Services Summary
##################################################

echo
echo "=== Services ==="

$KUBECTL get svc -n prometheus

##################################################
# Final Summary
##################################################

echo
echo "======================================================"
echo " Prometheus Validation Completed Successfully"
echo "======================================================"
echo
