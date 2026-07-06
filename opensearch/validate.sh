#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

for BIN in kubectl curl jq
do
  if ! command -v "$BIN" >/dev/null 2>&1
  then
    echo "[ERROR] Missing dependency: $BIN"
    exit 1
  fi
done

echo
echo "======================================"
echo " OpenSearch Validation"
echo "======================================"
echo



##
# Validation
##

echo
echo "=== Validation ==="

$KUBECTL get opensearchclusters.opensearch.org \
  -n opensearch

# --- Cluster Health Check (CRD status) ---
HEALTH=$($KUBECTL get opensearchclusters.opensearch.org \
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
OPENSEARCH_POD=$($KUBECTL get pod \
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

OS_PASS=$($KUBECTL get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$OS_PASS" ]; then
  echo
  echo "[ERROR] Could not retrieve admin password from secret shopixy-search-admin-password"
  exit 1
fi

# --- Cluster Health API Check ---
echo "[INFO] Checking OpenSearch cluster health API..."

CLUSTER_HEALTH=$($KUBECTL exec -n opensearch "$OPENSEARCH_POD" \
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

SNAP_REPO_STATUS=$($KUBECTL exec -n opensearch "$OPENSEARCH_POD" \
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

$KUBECTL get deployment \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n opensearch \
  --no-headers \
  | grep -q "1/1"

echo "[OK] Exporter deployment healthy"

# --- Summary ---
echo
$KUBECTL get pods \
  -n opensearch \
  -l opensearch.org/opensearch-cluster=shopixy-search

$KUBECTL get cronjob \
  -n opensearch

$KUBECTL get servicemonitor \
  -A | grep opensearch || true

echo
echo "======================================================"
echo " OpenSearch Validation Completed Successfully"
echo "======================================================"
echo
