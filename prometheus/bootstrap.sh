#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"
HELM="sudo -E helm --kubeconfig=${KUBECONFIG}"

echo
echo "======================================================"
echo "     Shopixy Prometheus Production Bootstrap"
echo "======================================================"
echo

##################################################
# Required Files
##################################################

REQUIRED_FILES=(
  "values.yaml"
  "custom-values.yaml"
  "prometheus-ingress.yaml"
)

for FILE in "${REQUIRED_FILES[@]}"
do
  if [ ! -f "${ROOT_DIR}/${FILE}" ]
  then
    echo
    echo "[ERROR] Missing file:"
    echo "  ${FILE}"
    echo
    exit 1
  fi
done

echo "[OK] Bootstrap files verified"

##################################################
# Required Binaries
##################################################

for BIN in kubectl helm
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
# Helm Repository
##################################################

echo
echo "=== Helm Repository ==="

if ! helm repo list | awk '{print $1}' | grep -q '^prometheus-community$'
then

    helm repo add prometheus-community \
      https://prometheus-community.github.io/helm-charts

fi

helm repo update

##################################################
# Install / Upgrade
##################################################

echo
echo "=== Installing Prometheus ==="

$HELM upgrade --install prometheus \
    prometheus-community/kube-prometheus-stack \
    -n prometheus \
    --create-namespace \
    -f "${ROOT_DIR}/custom-values.yaml" \
    --wait

echo "[OK] Helm deployment completed"

##################################################
# Wait Operator
##################################################

echo
echo "=== Waiting Operator ==="

$KUBECTL rollout status \
deployment/prometheus-kube-prometheus-operator \
-n prometheus \
--timeout=10m

echo "[OK] Operator ready"

##################################################
# Wait kube-state-metrics
##################################################

echo
echo "=== Waiting kube-state-metrics ==="

$KUBECTL rollout status \
deployment/prometheus-kube-state-metrics \
-n prometheus \
--timeout=10m

echo "[OK] kube-state-metrics ready"

##################################################
# Wait Node Exporter
##################################################

echo
echo "=== Waiting node-exporter ==="

$KUBECTL rollout status \
daemonset/prometheus-prometheus-node-exporter \
-n prometheus \
--timeout=10m

echo "[OK] node-exporter ready"

##################################################
# Wait Prometheus
##################################################

echo
echo "=== Waiting Prometheus ==="

$KUBECTL rollout status \
statefulset/prometheus-prometheus-kube-prometheus-prometheus \
-n prometheus \
--timeout=15m

echo "[OK] Prometheus ready"

echo
echo "=== Verifying Service ==="

$KUBECTL get svc \
prometheus-kube-prometheus-prometheus \
-n prometheus >/dev/null

echo "[OK] Service verified"

##################################################
# Ingress
##################################################

echo
echo "=== Applying Ingress ==="

$KUBECTL apply \
-f "${ROOT_DIR}/prometheus-ingress.yaml"

echo "[OK] Ingress applied"

##################################################
# Verify Ingress
##################################################

$KUBECTL get ingress prometheus \
-n prometheus >/dev/null

echo "[OK] Ingress verified"

##################################################
# Final Status
##################################################

echo
echo "======================================================"
echo " Prometheus Bootstrap Completed Successfully"
echo "======================================================"
echo

