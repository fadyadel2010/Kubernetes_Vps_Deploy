#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

for BIN in kubectl
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "[ERROR] Missing dependency: $BIN"
        exit 1
    fi
done

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

MINIO_POD=$(
$KUBECTL get pod \
    -n minio \
    -l app=minio \
    -o jsonpath='{.items[0].metadata.name}'
)

[ -n "$MINIO_POD" ] || {
    echo "[ERROR] MinIO pod not found"
    exit 1
}

ROOT_USER=$(
$KUBECTL get secret minio-secret \
    -n minio \
    -o jsonpath='{.data.root-user}' | base64 -d
)

ROOT_PASS=$(
$KUBECTL get secret minio-secret \
    -n minio \
    -o jsonpath='{.data.root-password}' | base64 -d
)

echo
echo "======================================================"
echo " MinIO Validation"
echo "======================================================"
echo

########################################################
# Storage
########################################################

$KUBECTL get pvc minio-storage \
    -n minio >/dev/null

echo "[OK] PVC exists"

########################################################
# Service
########################################################

$KUBECTL get svc minio \
    -n minio >/dev/null

echo "[OK] Service exists"

########################################################
# Ingress
########################################################

$KUBECTL get ingress minio \
    -n minio >/dev/null

echo "[OK] Ingress exists"

########################################################
# MinIO Client Authentication
########################################################

$KUBECTL exec -n minio "$MINIO_POD" -- \
mc alias remove local >/dev/null 2>&1 || true

$KUBECTL exec -n minio "$MINIO_POD" -- \
mc alias set \
local \
http://localhost:9000 \
"$ROOT_USER" \
"$ROOT_PASS" >/dev/null

echo "[OK] MinIO client authenticated"

########################################################
# MinIO Health
########################################################

$KUBECTL exec -n minio "$MINIO_POD" -- \
mc admin info local >/dev/null

echo "[OK] MinIO API reachable"

########################################################
# Buckets
########################################################

for BUCKET in \
    postgres-backups \
    opensearch-snapshots \
    mongodb-backups
do

    $KUBECTL exec -n minio "$MINIO_POD" -- \
        mc ls "local/$BUCKET" >/dev/null

    echo "[OK] Bucket verified: $BUCKET"

done

########################################################
# Pod Health
########################################################

$KUBECTL wait \
    --for=condition=Ready \
    pod/"$MINIO_POD" \
    -n minio \
    --timeout=30s >/dev/null

echo "[OK] Pod Ready"

echo
echo "======================================================"
echo " MinIO Validation Completed Successfully"
echo "======================================================"
echo
