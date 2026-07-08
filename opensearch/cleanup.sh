#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "======================================================"
echo "      Shopixy OpenSearch Full Cleanup"
echo "======================================================"
echo

#########################################
# Helm Releases
#########################################

echo "=== Removing Helm Releases ==="

sudo -E helm uninstall opensearch-exporter \
    -n opensearch 2>/dev/null || true

sudo -E helm uninstall opensearch-operator \
    -n opensearch-system 2>/dev/null || true

echo "[OK] Helm releases removed"

#########################################
# OpenSearch Resources
#########################################

echo
echo "=== Removing OpenSearch Resources ==="

sudo kubectl delete opensearchclusters.opensearch.org \
    --all -n opensearch --ignore-not-found=true || true

sudo kubectl delete opensearchclusters.opensearch.opster.io \
    --all -n opensearch --ignore-not-found=true || true

echo "[OK] Cluster resources removed"

#########################################
# Namespaces
#########################################

echo
echo "=== Removing Namespaces ==="

sudo kubectl delete namespace opensearch \
    --ignore-not-found=true \
    --wait=true || true

sudo kubectl delete namespace opensearch-system \
    --ignore-not-found=true \
    --wait=true || true

echo "[OK] Namespaces removed"

#########################################
# CRDs
#########################################

echo
echo "=== Removing CRDs ==="

sudo kubectl get crd \
| awk '/opensearch(\.opster\.io|\.org)/ {print $1}' \
| xargs -r sudo kubectl delete crd

echo "[OK] CRDs removed"

#########################################
# RBAC
#########################################

echo
echo "=== Removing RBAC ==="

sudo kubectl delete clusterrole \
    opensearch-operator \
    opensearch-operator-metrics \
    opensearch-operator-proxy \
    --ignore-not-found=true

sudo kubectl delete clusterrolebinding \
    opensearch-operator \
    opensearch-operator-proxy \
    --ignore-not-found=true

echo "[OK] RBAC removed"

#########################################
# Webhooks
#########################################

echo
echo "=== Removing Webhooks ==="

sudo kubectl delete validatingwebhookconfiguration \
    opensearch-operator-validating-webhook-configuration \
    --ignore-not-found=true

echo "[OK] Webhooks removed"

#########################################
# Certificates
#########################################

echo
echo "=== Removing Certificates ==="

sudo kubectl delete certificate \
    --all \
    -n opensearch-system \
    --ignore-not-found=true || true

sudo kubectl delete issuer \
    --all \
    -n opensearch-system \
    --ignore-not-found=true || true

echo "[OK] Certificates removed"

#########################################
# Final Check
#########################################

echo
echo "======================================================"
echo " Remaining OpenSearch Resources"
echo "======================================================"

sudo kubectl get crd | grep opensearch || true
sudo kubectl get clusterrole | grep opensearch || true
sudo kubectl get clusterrolebinding | grep opensearch || true
sudo kubectl get ns | grep opensearch || true
sudo -E helm list -A | grep opensearch || true

echo
echo "======================================================"
echo " Cleanup Completed"
echo "======================================================"
