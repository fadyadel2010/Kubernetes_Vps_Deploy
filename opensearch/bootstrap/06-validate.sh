#!/usr/bin/env bash

set -euo pipefail

source scripts/common.sh

NAMESPACE="opensearch"
CLUSTER_NAME="shopixy-search"

echo
echo "======================================"
echo " OpenSearch Stack Certification"
echo "======================================"
echo

FAILURES=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES + 1)); }

#
# Cluster Exists
#

if sudo kubectl get opensearchclusters.opensearch.org \
  "$CLUSTER_NAME" \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  pass "Cluster exists"
else
  fail "Cluster exists"
fi

#
# Cluster Health
#

HEALTH=$(
sudo kubectl get opensearchclusters.opensearch.org \
  "$CLUSTER_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.health}' 2>/dev/null || true
)

if [ "$HEALTH" = "green" ]
then
  pass "Cluster health green"
else
  fail "Cluster health ($HEALTH)"
fi

#
# Node Count
#

NODES=$(
sudo kubectl get opensearchclusters.opensearch.org \
  "$CLUSTER_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.availableNodes}' 2>/dev/null || echo "0"
)

if [ "$NODES" -ge 3 ]
then
  pass "Node count ($NODES)"
else
  fail "Node count ($NODES)"
fi

#
# Snapshot CronJob
#

if sudo kubectl get cronjob \
  opensearch-snapshot \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  pass "Snapshot CronJob"
else
  fail "Snapshot CronJob"
fi

#
# Snapshot Repository
#

OS_USER="$(get_admin_user)"
OS_PASS="$(get_admin_password)"

REPO_CODE=$(
curl -sk \
  -u "$OS_USER:$OS_PASS" \
  https://shopixy-search:9200/_snapshot/shopixy-snapshots \
  -o /dev/null \
  -w "%{http_code}"
)

if [ "$REPO_CODE" = "200" ]
then
  pass "Snapshot Repository"
else
  fail "Snapshot Repository"
fi

#
# Exporter Deployment
#

if sudo kubectl get deployment \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  pass "Exporter deployment"
else
  fail "Exporter deployment"
fi

#
# Exporter Ready
#

READY=$(
sudo kubectl get deployment \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"
)

if [ "${READY:-0}" -ge 1 ]
then
  pass "Exporter ready"
else
  fail "Exporter ready"
fi

#
# ServiceMonitor
#

if sudo kubectl get servicemonitor \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n prometheus >/dev/null 2>&1
then
  pass "ServiceMonitor"
else
  fail "ServiceMonitor"
fi

#
# Metrics Endpoint
#

EXPORTER_POD=$(
sudo kubectl get pod \
  -n "$NAMESPACE" \
  -l app.kubernetes.io/name=prometheus-elasticsearch-exporter \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
)

if [ -n "$EXPORTER_POD" ]
then
  if sudo kubectl exec \
      -n "$NAMESPACE" \
      "$EXPORTER_POD" \
      -- wget -qO- http://localhost:9108/metrics \
      | grep -q elasticsearch_cluster_health_status
  then
    pass "Metrics endpoint"
  else
    fail "Metrics endpoint"
  fi
else
  fail "Metrics endpoint"
fi

#
# Final Result
#

echo
echo "======================================"

if [ "$FAILURES" -eq 0 ]
then
  echo " OpenSearch Certification: PASS "
  echo
  echo " Cluster     : PASS"
  echo " Backup      : PASS"
  echo " Monitoring  : PASS"
  echo
  echo " Overall     : PASS"
  echo "======================================"
  exit 0
else
  echo " OpenSearch Certification: FAIL "
  echo
  echo " Failed Checks: $FAILURES"
  echo "======================================"
  exit 1
fi
