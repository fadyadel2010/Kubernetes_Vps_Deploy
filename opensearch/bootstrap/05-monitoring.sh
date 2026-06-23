#!/usr/bin/env bash

set -euo pipefail

source scripts/common.sh

NAMESPACE="opensearch"

log_info "Configuring Monitoring"

#
# Helm Repository
#

if ! helm repo list | awk '{print $1}' | grep -q '^prometheus-community$'
then
  log_info "Adding Prometheus Helm repository"

  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts
else
  log_skip "Prometheus repository already exists"
fi

helm repo update

#
# Exporter Secret
#

if sudo kubectl get secret opensearch-exporter-secret \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  log_skip "Exporter secret already exists"
else
  log_info "Creating exporter secret"

  sudo kubectl apply \
    -f monitoring/exporter-secret.yaml

  log_ok "Exporter secret created"
fi

#
# Exporter Release
#

if helm status opensearch-exporter \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  log_info "Upgrading exporter"

  helm upgrade opensearch-exporter \
    prometheus-community/prometheus-elasticsearch-exporter \
    -n "$NAMESPACE" \
    -f monitoring/exporter-values.yaml
else
  log_info "Installing exporter"

  helm install opensearch-exporter \
    prometheus-community/prometheus-elasticsearch-exporter \
    -n "$NAMESPACE" \
    -f monitoring/exporter-values.yaml
fi

#
# Wait For Rollout
#

wait_for_rollout \
  deployment \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  "$NAMESPACE"

#
# Verify Pod Ready
#

sudo kubectl wait \
  --for=condition=Ready \
  pod \
  -l app.kubernetes.io/name=prometheus-elasticsearch-exporter \
  -n "$NAMESPACE" \
  --timeout=10m

log_ok "Exporter pod ready"

#
# Verify ServiceMonitor
#

if sudo kubectl get servicemonitor \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  -n prometheus >/dev/null 2>&1
then
  log_ok "ServiceMonitor found"
else
  echo
  echo "[ERROR] ServiceMonitor missing"
  exit 1
fi

#
# Verify Metrics Endpoint
#

EXPORTER_POD=$(
sudo kubectl get pod \
  -n "$NAMESPACE" \
  -l app.kubernetes.io/name=prometheus-elasticsearch-exporter \
  -o jsonpath='{.items[0].metadata.name}'
)

if sudo kubectl exec \
  -n "$NAMESPACE" \
  "$EXPORTER_POD" \
  -- wget -qO- http://localhost:9108/metrics \
  | grep -q elasticsearch_cluster_health_status
then
  log_ok "Exporter metrics available"
else
  echo
  echo "[ERROR] Exporter metrics unavailable"
  exit 1
fi

log_ok "Monitoring bootstrap completed"
