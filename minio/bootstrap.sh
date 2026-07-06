#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "======================================================"
echo "          Shopixy MinIO Production Bootstrap"
echo "======================================================"
echo

##################################################
# Required Files
##################################################

REQUIRED_FILES=(
  "namespace.yaml"
  "minio-secret.yaml"
  "minio-pvc.yaml"
  "minio-service.yaml"
  "minio-deployment.yaml"
  "minio-ingress.yaml"
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

for BIN in sudo kubectl curl
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
# Namespace
##################################################

echo
echo "=== Namespace ==="

sudo kubectl apply -f "${ROOT_DIR}/namespace.yaml"

echo "[OK] Namespace ready"

##################################################
# Secret
##################################################

echo
echo "=== Secret ==="

sudo kubectl apply -f "${ROOT_DIR}/minio-secret.yaml"

echo "[OK] Secret ready"

##################################################
# PVC
##################################################

echo
echo "=== Persistent Storage ==="

sudo kubectl apply -f "${ROOT_DIR}/minio-pvc.yaml"

echo "[OK] PVC ready"

##################################################
# Service
##################################################

echo
echo "=== Service ==="

sudo kubectl apply -f "${ROOT_DIR}/minio-service.yaml"

echo "[OK] Service ready"

##################################################
# Deployment
##################################################

echo
echo "=== Deployment ==="

sudo kubectl apply -f "${ROOT_DIR}/minio-deployment.yaml"

sudo kubectl rollout status \
  deployment/minio \
  -n minio \
  --timeout=10m

echo "[OK] Deployment ready"

##################################################
# Ingress
##################################################

echo
echo "=== Ingress ==="

sudo kubectl apply -f "${ROOT_DIR}/minio-ingress.yaml"

echo "[OK] Ingress ready"

##################################################
# Resolve Pod
##################################################

MINIO_POD=$(
sudo kubectl get pod \
  -n minio \
  -l app=minio \
  -o jsonpath='{.items[0].metadata.name}'
)

if [ -z "$MINIO_POD" ]; then
  echo
  echo "[ERROR] No MinIO pod found"
  exit 1
fi

echo "[INFO] Using pod: $MINIO_POD"

##################################################
# Install MinIO Client
##################################################

echo
echo "=== Bucket Bootstrap ==="

sudo kubectl exec -n minio "$MINIO_POD" -- \
  sh -c '
    if ! command -v mc >/dev/null 2>&1; then
      curl -sSL \
        https://dl.min.io/client/mc/release/linux-amd64/mc \
        -o /tmp/mc

      chmod +x /tmp/mc

      mv /tmp/mc /usr/local/bin/mc
    fi
  '

##################################################
# Configure Alias
##################################################

ROOT_USER=$(
sudo kubectl get secret minio-secret \
  -n minio \
  -o jsonpath='{.data.root-user}' | base64 -d
)

ROOT_PASS=$(
sudo kubectl get secret minio-secret \
  -n minio \
  -o jsonpath='{.data.root-password}' | base64 -d
)

sudo kubectl exec -n minio "$MINIO_POD" -- \
  mc alias set local \
  http://localhost:9000 \
  "$ROOT_USER" \
  "$ROOT_PASS"

##################################################
# Buckets
##################################################

for BUCKET in \
  postgres-backups \
  opensearch-snapshots \
  mongodb-backups
do

  if sudo kubectl exec -n minio "$MINIO_POD" -- \
      mc ls local/"$BUCKET" >/dev/null 2>&1
  then

    echo "[SKIP] Bucket exists: $BUCKET"

  else

    sudo kubectl exec -n minio "$MINIO_POD" -- \
      mc mb local/"$BUCKET"

    echo "[OK] Bucket created: $BUCKET"

  fi

done

echo
echo "======================================================"
echo " MinIO Bootstrap Completed Successfully"
echo "======================================================"
echo

