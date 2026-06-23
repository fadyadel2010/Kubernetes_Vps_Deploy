#!/usr/bin/env bash

set -euo pipefail

echo
echo "======================================"
echo " OpenSearch Validation"
echo "======================================"
echo

echo "[1/6] Cluster Health"

kubectl get opensearchclusters.opensearch.org \
  shopixy-search \
  -n opensearch

echo
echo "[2/6] Pods"

kubectl get pods -n opensearch

echo
echo "[3/6] Snapshot CronJob"

kubectl get cronjob -n opensearch

echo
echo "[4/6] Exporter"

kubectl get deployment \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n opensearch

echo
echo "[5/6] ServiceMonitor"

kubectl get servicemonitor -A | grep opensearch || true

echo
echo "[6/6] Repository"

kubectl exec -n opensearch \
  shopixy-search-core-0 -- \
  curl -sk \
  -u "$(cat /mnt/admin-credentials/username):$(cat /mnt/admin-credentials/password)" \
  https://localhost:9200/_snapshot/shopixy-snapshots

echo
echo "Validation Completed"
