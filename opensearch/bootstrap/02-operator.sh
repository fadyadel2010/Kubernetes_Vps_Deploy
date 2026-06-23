#!/usr/bin/env bash

set -euo pipefail

source scripts/common.sh

log_info "Checking Helm"

require_binary helm
require_binary kubectl

if helm repo list 2>/dev/null | grep -q '^opensearch'
then
  log_skip "OpenSearch repository already exists"
else
  log_info "Adding OpenSearch Helm repository"

  helm repo add opensearch \
    https://opensearch-project.github.io/opensearch-k8s-operator/
fi

helm repo update

if helm status opensearch-operator \
  -n opensearch >/dev/null 2>&1
then
  log_skip "OpenSearch Operator already installed"

else

  log_info "Patching existing resource ownership annotations if needed"

  # Patch CRDs
  for RES in $(kubectl get crd -o name | grep -E 'opensearch\.(opster\.io|org)'); do
    kubectl annotate "$RES" \
      meta.helm.sh/release-name=opensearch-operator \
      meta.helm.sh/release-namespace=opensearch \
      --overwrite
    kubectl label "$RES" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite
  done

  # Patch ClusterRoles
  for RES in $(kubectl get clusterrole -o name | grep opensearch); do
    kubectl annotate "$RES" \
      meta.helm.sh/release-name=opensearch-operator \
      meta.helm.sh/release-namespace=opensearch \
      --overwrite
    kubectl label "$RES" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite
  done

  # Patch ClusterRoleBindings
  for RES in $(kubectl get clusterrolebinding -o name | grep opensearch); do
    kubectl annotate "$RES" \
      meta.helm.sh/release-name=opensearch-operator \
      meta.helm.sh/release-namespace=opensearch \
      --overwrite
    kubectl label "$RES" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite
  done

  log_info "Installing OpenSearch Operator"

  helm install opensearch-operator \
    opensearch/opensearch-operator \
    -n opensearch \
    -f operator/values.yaml

fi

# Dynamically find the operator deployment name and namespace
log_info "Detecting operator deployment"

OPERATOR_NS=$(
  kubectl get deployment -A \
    --field-selector=metadata.namespace!=opensearch-system \
    -l "app.kubernetes.io/instance=opensearch-operator" \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo ""
)

OPERATOR_DEPLOY=$(
  kubectl get deployment -A \
    --field-selector=metadata.namespace!=opensearch-system \
    -l "app.kubernetes.io/instance=opensearch-operator" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
)

# Fallback: search by name pattern if label selector returns nothing
if [ -z "$OPERATOR_DEPLOY" ]; then
  OPERATOR_NS=$(
    kubectl get deployment -A \
      -o json \
      | jq -r '.items[] | select(.metadata.name | test("opensearch-operator")) | select(.metadata.namespace != "opensearch-system") | .metadata.namespace' \
      | head -1
  )
  OPERATOR_DEPLOY=$(
    kubectl get deployment -A \
      -o json \
      | jq -r '.items[] | select(.metadata.name | test("opensearch-operator")) | select(.metadata.namespace != "opensearch-system") | .metadata.name' \
      | head -1
  )
fi

if [ -z "$OPERATOR_DEPLOY" ] || [ -z "$OPERATOR_NS" ]; then
  echo "[ERROR] Could not detect operator deployment"
  exit 1
fi

log_info "Operator deployment: $OPERATOR_DEPLOY in namespace: $OPERATOR_NS"

wait_for_rollout \
  deployment \
  "$OPERATOR_DEPLOY" \
  "$OPERATOR_NS"

log_ok "Operator ready"
