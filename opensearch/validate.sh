#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "======================================"
echo " OpenSearch Validation"
echo "======================================"
echo

OPENSEARCH_CRD="opensearchclusters.opensearch.org"

echo
echo "=== Validation ==="

sudo kubectl get "${OPENSEARCH_CRD}" -n opensearch

HEALTH=$(sudo kubectl get "${OPENSEARCH_CRD}" \
    shopixy-search \
    -n opensearch \
    -o jsonpath='{.status.health}')

if [ "$HEALTH" != "green" ]; then
    echo "[ERROR] Cluster health = ${HEALTH}"
    exit 1
fi

echo "[OK] Cluster health = green"

echo
echo "[INFO] Waiting for all OpenSearch Pods to become Ready..."

sudo kubectl wait \
  --for=condition=Ready \
  pod \
  -l opensearch.org/opensearch-cluster=shopixy-search \
  -n opensearch \
  --timeout=15m

echo "[OK] All OpenSearch Pods are Ready"

POD=$(sudo kubectl get pod \
    -n opensearch \
    -l opensearch.org/opensearch-cluster=shopixy-search \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')

echo "[INFO] Using pod: ${POD}"

OS_PASS=$(sudo kubectl get secret \
    shopixy-search-admin-password \
    -n opensearch \
    -o jsonpath='{.data.password}' | base64 -d)

echo
echo "[INFO] Checking OpenSearch Cluster Health API..."

STATUS=$(sudo kubectl exec \
    -n opensearch \
    "${POD}" \
    -- \
    curl -sk \
    -u admin:${OS_PASS} \
    https://localhost:9200/_cluster/health \
    | jq -r '.status')

if [ "$STATUS" != "green" ]; then
    echo "[ERROR] OpenSearch API status = ${STATUS}"
    exit 1
fi

echo "[OK] OpenSearch Health API = green"

echo
echo "[INFO] Checking Exporter Connectivity..."

EXPORTER_STATUS=$(sudo kubectl exec \
    -n opensearch \
    deploy/opensearch-exporter-prometheus-elasticsearch-exporter \
    -- \
    wget -qO- http://localhost:9108/metrics \
    | awk '/^elasticsearch_clusterinfo_up/{print $2}')

if [ "$EXPORTER_STATUS" != "1" ]; then
    echo "[ERROR] Exporter is NOT connected to OpenSearch"
    exit 1
fi

echo "[OK] Exporter connected successfully"

echo
echo "[INFO] Checking ServiceMonitor..."

sudo kubectl get servicemonitor \
    opensearch-exporter-prometheus-elasticsearch-exporter \
    -n prometheus >/dev/null

echo "[OK] ServiceMonitor exists"

echo
echo "[INFO] Checking OpenSearch Services..."

sudo kubectl get svc -n opensearch

echo
echo "[INFO] Checking OpenSearch Pods..."

sudo kubectl get pods -n opensearch

echo
echo "======================================"
echo " OpenSearch Validation PASSED"
echo "======================================"
echo
