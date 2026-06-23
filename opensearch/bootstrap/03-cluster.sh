#!/usr/bin/env bash

set -euo pipefail

source scripts/common.sh

CLUSTER_NAME="shopixy-search"
NAMESPACE="opensearch"

log_info "Checking OpenSearch Cluster"

if sudo kubectl get opensearchclusters.opensearch.org \
  "$CLUSTER_NAME" \
  -n "$NAMESPACE" >/dev/null 2>&1
then
  log_skip "OpenSearch Cluster already exists"
else
  log_info "Creating OpenSearch Cluster"

  sudo kubectl apply \
    -f cluster/opensearch-cluster.yaml

  log_ok "Cluster manifest applied"
fi

log_info "Waiting for cluster resource"

sudo kubectl wait \
  --for=jsonpath='{.status.phase}'=RUNNING \
  opensearchclusters.opensearch.org/"$CLUSTER_NAME" \
  -n "$NAMESPACE" \
  --timeout=30m

log_info "Waiting for all OpenSearch pods"

sudo kubectl wait \
  --for=condition=Ready \
  pod \
  -l opensearch.org/opensearch-cluster="$CLUSTER_NAME" \
  -n "$NAMESPACE" \
  --timeout=30m

HEALTH=$(
sudo kubectl get opensearchclusters.opensearch.org \
  "$CLUSTER_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.health}'
)

if [ "$HEALTH" != "green" ]
then
  log_warn "Cluster health is $HEALTH"
else
  log_ok "Cluster health is green"
fi

log_ok "OpenSearch Cluster ready"
