#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

for BIN in kubectl
do
  if ! command -v "$BIN" >/dev/null 2>&1
  then
    echo "[ERROR] Missing dependency: $BIN"
    exit 1
  fi
done

echo "========================================="
echo "Deploying Traefik HelmChartConfig"
echo "========================================="

if [ ! -f "$SCRIPT_DIR/base/helmchartconfig.yaml" ]; then
  echo "[ERROR] Missing file: base/helmchartconfig.yaml"
  exit 1
fi

sudo cp "$SCRIPT_DIR/base/helmchartconfig.yaml" \
/var/lib/rancher/k3s/server/manifests/traefik-config.yaml

echo
echo "Waiting for Traefik rollout..."

echo "Waiting for k3s to detect manifest..."

 $KUBECTL rollout status deployment/traefik \
-n kube-system \
--timeout=180s

AVAILABLE=$(
$KUBECTL get deployment traefik \
  -n kube-system \
  -o jsonpath='{.status.availableReplicas}'
)

[ "${AVAILABLE:-0}" -ge 1 ] || {
  echo "[ERROR] Traefik is not available"
  exit 1
}

echo "[OK] Traefik is available"

$KUBECTL get svc traefik -n kube-system >/dev/null || {
    echo "[ERROR] Traefik Service not found"
    exit 1
}

echo "[OK] Traefik Service"

echo
echo "========================================="
echo " Traefik Bootstrap Completed Successfully"
echo "========================================="
echo
