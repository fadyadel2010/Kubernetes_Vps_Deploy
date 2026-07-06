#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "======================================================"
echo "      Shopixy OpenSearch Production Bootstrap"
echo "======================================================"
echo

##
# Required Files Check
##

REQUIRED_FILES=(
  "namespace.yaml"
  "operator/values.yaml"
  "cluster/opensearch-cluster.yaml"
  "monitoring/exporter-values.yaml"
  "monitoring/exporter-secret.yaml"
  "snapshots/minio-s3-secret.yaml"
  "snapshots/snapshot-secret.yaml"
  "snapshots/snapshot-cronjob.yaml"
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

##
# Required Binaries
##

for BIN in sudo kubectl helm curl jq
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

##
# Namespace
##

echo
echo "=== Namespace ==="

if sudo kubectl get namespace opensearch >/dev/null 2>&1
then
  echo "[SKIP] Namespace already exists"
else
  sudo kubectl apply -f "${ROOT_DIR}/namespace.yaml"
  echo "[OK] Namespace created"
fi

##
# OpenSearch Helm Repo
##

echo
echo "=== Helm Repositories ==="

if sudo -E helm repo list | awk '{print $1}' | grep -q '^opensearch$'
then
  echo "[SKIP] OpenSearch repo already exists"
else
  sudo -E helm repo add opensearch \
    https://opensearch-project.github.io/opensearch-k8s-operator/
  echo "[OK] OpenSearch repo added"
fi

if sudo -E helm repo list 2>/dev/null | grep -q '^prometheus-community'
then
  echo "[SKIP] Prometheus repo already exists"
else
  sudo -E helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts
  echo "[OK] Prometheus repo added"
fi

sudo -E helm repo update

##
# Operator
##

echo
echo "=== OpenSearch Operator ==="

if sudo -E helm status opensearch-operator \
  -n opensearch-system >/dev/null 2>&1
then

  echo "[SKIP] Operator already installed"

else

  sudo kubectl create namespace opensearch-system \
    --dry-run=client -o yaml | sudo kubectl apply -f -

  sudo -E helm install opensearch-operator \
    opensearch/opensearch-operator \
    -n opensearch-system \
    -f "${ROOT_DIR}/operator/values.yaml"

  echo "[OK] Operator installed"

fi

sudo kubectl rollout status \
  deployment/opensearch-operator \
  -n opensearch-system \
  --timeout=20m

echo "[OK] Operator ready"

##
# Cluster
##

echo
echo "=== OpenSearch Cluster ==="

if sudo kubectl get opensearchclusters.opensearch.org \
  shopixy-search \
  -n opensearch >/dev/null 2>&1
then

  echo "[SKIP] Cluster already exists"

else

  sudo kubectl apply \
    -f "${ROOT_DIR}/cluster/opensearch-cluster.yaml"

  echo "[OK] Cluster manifest applied"

fi

echo "[OK] Cluster ready"

##
# Backup Infrastructure
##

echo
echo "=== Backup Infrastructure ==="

sudo kubectl apply -f "${ROOT_DIR}/snapshots/minio-s3-secret.yaml"
sudo kubectl apply -f "${ROOT_DIR}/snapshots/snapshot-secret.yaml"
sudo kubectl apply -f "${ROOT_DIR}/snapshots/snapshot-cronjob.yaml"

echo "[INFO] Verifying backup resources..."

sudo kubectl get secret opensearch-s3-credentials \
  -n opensearch \
  --no-headers \
  -o name \
  | grep -q "secret/opensearch-s3-credentials" \
  || { echo "[ERROR] Secret opensearch-s3-credentials not found"; exit 1; }
echo "[OK] Secret opensearch-s3-credentials exists"

sudo kubectl get secret opensearch-snapshot-job \
  -n opensearch \
  --no-headers \
  -o name \
  | grep -q "secret/opensearch-snapshot-job" \
  || { echo "[ERROR] Secret opensearch-snapshot-job not found"; exit 1; }
echo "[OK] Secret opensearch-snapshot-job exists"

sudo kubectl get cronjob opensearch-snapshot \
  -n opensearch \
  --no-headers \
  -o name \
  | grep -q "cronjob.batch/opensearch-snapshot" \
  || { echo "[ERROR] CronJob opensearch-snapshot not found"; exit 1; }
echo "[OK] CronJob opensearch-snapshot exists"

echo "[OK] Backup infrastructure ready"

##
# Monitoring
##

echo
echo "=== Monitoring ==="

sudo kubectl apply -f "${ROOT_DIR}/monitoring/exporter-secret.yaml"

sudo -E helm upgrade --install \
  opensearch-exporter \
  prometheus-community/prometheus-elasticsearch-exporter \
  -n opensearch \
  -f "${ROOT_DIR}/monitoring/exporter-values.yaml"

sudo kubectl rollout status \
  deployment/opensearch-exporter-prometheus-elasticsearch-exporter \
  -n opensearch \
  --timeout=20m

echo "[OK] Monitoring ready"

echo
echo "======================================================"
echo " OpenSearch Bootstrap Completed Successfully"
echo "======================================================"
echo
