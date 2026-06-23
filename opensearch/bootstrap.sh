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
# Root Check
##

if [ "$EUID" -ne 0 ]; then
  echo
  echo "[ERROR] Please run using:"
  echo
  echo "sudo bash bootstrap.sh"
  echo
  exit 1
fi

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

for BIN in kubectl helm curl jq
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

if kubectl get namespace opensearch >/dev/null 2>&1
then
  echo "[SKIP] Namespace already exists"
else
  kubectl apply -f "${ROOT_DIR}/namespace.yaml"
  echo "[OK] Namespace created"
fi

##
# OpenSearch Helm Repo
##

echo
echo "=== Helm Repositories ==="

if helm repo list | awk '{print $1}' | grep -q '^opensearch$'
then
  echo "[SKIP] OpenSearch repo already exists"
else
  helm repo add opensearch \
    https://opensearch-project.github.io/opensearch-k8s-operator/
  echo "[OK] OpenSearch repo added"
fi

if helm repo list 2>/dev/null | grep -q '^prometheus-community'
then
  echo "[SKIP] Prometheus repo already exists"
else
  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts
  echo "[OK] Prometheus repo added"
fi

helm repo update

##
# Operator
##

echo
echo "=== OpenSearch Operator ==="

if helm status opensearch-operator \
  -n opensearch-system >/dev/null 2>&1
then

  echo "[SKIP] Operator already installed"

else

  kubectl create namespace opensearch-system \
    --dry-run=client -o yaml | kubectl apply -f -

  helm install opensearch-operator \
    opensearch/opensearch-operator \
    -n opensearch-system \
    -f "${ROOT_DIR}/operator/values.yaml"

  echo "[OK] Operator installed"

fi

kubectl rollout status \
  deployment/opensearch-operator \
  -n opensearch-system \
  --timeout=20m

echo "[OK] Operator ready"

##
# Cluster
##

echo
echo "=== OpenSearch Cluster ==="

if kubectl get opensearchclusters.opensearch.org \
  shopixy-search \
  -n opensearch >/dev/null 2>&1
then

  echo "[SKIP] Cluster already exists"

else

  kubectl apply \
    -f "${ROOT_DIR}/cluster/opensearch-cluster.yaml"

  echo "[OK] Cluster manifest applied"

fi

echo "[OK] Cluster ready"

##
# Backup Infrastructure
##

echo
echo "=== Backup Infrastructure ==="

kubectl apply -f "${ROOT_DIR}/snapshots/minio-s3-secret.yaml"
kubectl apply -f "${ROOT_DIR}/snapshots/snapshot-secret.yaml"
kubectl apply -f "${ROOT_DIR}/snapshots/snapshot-cronjob.yaml"

echo "[INFO] Verifying backup resources..."

kubectl get secret opensearch-s3-credentials \
  -n opensearch \
  --no-headers \
  -o name \
  | grep -q "secret/opensearch-s3-credentials" \
  || { echo "[ERROR] Secret opensearch-s3-credentials not found"; exit 1; }
echo "[OK] Secret opensearch-s3-credentials exists"

kubectl get secret opensearch-snapshot-job \
  -n opensearch \
  --no-headers \
  -o name \
  | grep -q "secret/opensearch-snapshot-job" \
  || { echo "[ERROR] Secret opensearch-snapshot-job not found"; exit 1; }
echo "[OK] Secret opensearch-snapshot-job exists"

kubectl get cronjob opensearch-snapshot \
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

kubectl apply -f "${ROOT_DIR}/monitoring/exporter-secret.yaml"

helm upgrade --install \
  opensearch-exporter \
  prometheus-community/prometheus-elasticsearch-exporter \
  -n opensearch \
  -f "${ROOT_DIR}/monitoring/exporter-values.yaml"

kubectl rollout status \
  deployment/opensearch-exporter-prometheus-elasticsearch-exporter \
  -n opensearch \
  --timeout=20m

echo "[OK] Monitoring ready"

##
# Validation
##

echo
echo "=== Validation ==="

kubectl get opensearchclusters.opensearch.org \
  -n opensearch

# --- Cluster Health Check (CRD status) ---
HEALTH=$(kubectl get opensearchclusters.opensearch.org \
  shopixy-search \
  -n opensearch \
  -o jsonpath='{.status.health}')

if [ "$HEALTH" != "green" ]; then
  echo
  echo "[ERROR] Cluster health = $HEALTH (expected: green)"
  exit 1
fi

echo "[OK] Cluster health = green"

# --- Resolve shared vars once (Pod + Password) ---
# Secret name follows operator convention: <cluster-name>-admin-password
# Confirmed via: kubectl get secret -n opensearch | grep admin
OPENSEARCH_POD=$(kubectl get pod \
  -n opensearch \
  -l opensearch.org/opensearch-cluster=shopixy-search \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

if [ -z "$OPENSEARCH_POD" ]; then
  echo
  echo "[ERROR] No running OpenSearch pod found"
  exit 1
fi

echo "[INFO] Using pod: $OPENSEARCH_POD"

OS_PASS=$(kubectl get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$OS_PASS" ]; then
  echo
  echo "[ERROR] Could not retrieve admin password from secret shopixy-search-admin-password"
  exit 1
fi

# --- Cluster Health API Check ---
echo "[INFO] Checking OpenSearch cluster health API..."

CLUSTER_HEALTH=$(kubectl exec -n opensearch "$OPENSEARCH_POD" \
  -- curl -sk \
    -u "admin:${OS_PASS}" \
    "https://localhost:9200/_cluster/health" \
  | jq -r '.status')

if [ "$CLUSTER_HEALTH" != "green" ]; then
  echo
  echo "[ERROR] OpenSearch health API returned: $CLUSTER_HEALTH (expected: green)"
  exit 1
fi

echo "[OK] OpenSearch health API = green"

# --- Snapshot Repository Check ---
echo "[INFO] Checking snapshot repository registration..."

SNAP_REPO_STATUS=$(kubectl exec -n opensearch "$OPENSEARCH_POD" \
  -- curl -sk \
    -u "admin:${OS_PASS}" \
    "https://localhost:9200/_snapshot" \
  | jq 'keys | length')

if [ "$SNAP_REPO_STATUS" -eq 0 ]; then
  echo
  echo "[ERROR] No snapshot repositories registered in OpenSearch"
  exit 1
fi

echo "[OK] Snapshot repository registered ($SNAP_REPO_STATUS repo(s) found)"

echo "[INFO] Verifying exporter deployment..."

kubectl get deployment \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n opensearch \
  --no-headers \
  | grep -q "1/1"

echo "[OK] Exporter deployment healthy"

# --- Summary ---
echo
kubectl get pods \
  -n opensearch \
  -l opensearch.org/opensearch-cluster=shopixy-search

kubectl get cronjob \
  -n opensearch

kubectl get servicemonitor \
  -A | grep opensearch || true

echo
echo "======================================================"
echo " OpenSearch Bootstrap Completed Successfully"
echo "======================================================"
echo
