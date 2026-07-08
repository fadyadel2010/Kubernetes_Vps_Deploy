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
  "snapshots/s3-keystore-secret.yaml"
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

sudo kubectl create namespace opensearch-system \
  --dry-run=client -o yaml | sudo kubectl apply -f -

sudo -E helm upgrade --install \
  opensearch-operator \
  opensearch/opensearch-operator \
  --version 3.0.2 \
  -n opensearch-system \
  -f "${ROOT_DIR}/operator/values.yaml"

echo "[OK] Operator installed"

sudo kubectl rollout status \
  deployment/opensearch-operator \
  -n opensearch-system \
  --timeout=20m

echo "[OK] Operator ready"

echo
echo "[INFO] Validating Operator resources..."

sudo kubectl get clusterrole opensearch-operator >/dev/null \
  || { echo "[ERROR] ClusterRole missing"; exit 1; }

sudo kubectl get clusterrolebinding opensearch-operator >/dev/null \
  || { echo "[ERROR] ClusterRoleBinding missing"; exit 1; }

sudo kubectl get deployment opensearch-operator \
  -n opensearch-system >/dev/null \
  || { echo "[ERROR] Operator deployment missing"; exit 1; }

echo "[OK] Operator validation passed"

##
# Cluster
##

echo
echo "=== OpenSearch Cluster ==="

echo
echo "[INFO] Detecting OpenSearch API Group..."

OPENSEARCH_CRD="opensearchclusters.opensearch.org"

echo "[OK] Using API: ${OPENSEARCH_CRD}"

echo "[OK] Using API: ${OPENSEARCH_CRD}"

if sudo kubectl get "${OPENSEARCH_CRD}" \
    shopixy-search \
    -n opensearch >/dev/null 2>&1
then

    echo "[SKIP] Cluster already exists"

else

    sudo kubectl apply \
      -f "${ROOT_DIR}/cluster/opensearch-cluster.yaml"

    echo "[OK] Cluster manifest applied"

fi

echo "[INFO] Waiting for OpenSearch cluster..."

sudo kubectl wait \
  --for=jsonpath='{.status.phase}'=RUNNING \
  "${OPENSEARCH_CRD}/shopixy-search" \
  -n opensearch \
  --timeout=30m

echo "[OK] Cluster is running"

##
# Snapshot Repository
##

echo
echo "=== Snapshot Repository ==="

"${ROOT_DIR}/snapshots/register-repository.sh"

echo "[OK] Snapshot repository ready"

##
# Snapshot Job Secret
##

echo
echo "=== Snapshot Job Secret ==="

OS_PASS=$(sudo kubectl get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.password}' | base64 -d)

OS_USER=$(sudo kubectl get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.username}' | base64 -d)

ES_URI="https://${OS_USER}:${OS_PASS}@shopixy-search:9200"

sudo kubectl create secret generic opensearch-snapshot-job \
  -n opensearch \
  --from-literal=OS_USER=admin \
  --from-literal=OS_PASS="${OS_PASS}" \
  --dry-run=client -o yaml | sudo kubectl apply -f -

echo "[OK] Snapshot job secret created"

##
# Exporter Secret
##

echo
echo "=== Exporter Secret ==="

OS_USER=$(sudo kubectl get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.username}' | base64 -d)

OS_PASS=$(sudo kubectl get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.password}' | base64 -d)

sudo kubectl create secret generic opensearch-exporter-secret \
  -n opensearch \
  --from-literal=ES_USER="${OS_USER}" \
  --from-literal=ES_PASS="${OS_PASS}" \
  --dry-run=client -o yaml | sudo kubectl apply -f -

echo "[OK] Exporter secret created"


##
# Backup Infrastructure
##

echo
echo "=== Backup Infrastructure ==="

sudo kubectl apply -f "${ROOT_DIR}/snapshots/minio-s3-secret.yaml"
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


sudo -E helm upgrade --install \
  opensearch-exporter \
  prometheus-community/prometheus-elasticsearch-exporter \
  -n opensearch \
  -f "${ROOT_DIR}/monitoring/exporter-values.yaml" \
  --set-string es.uri="${ES_URI}"

sudo kubectl rollout status \
  deployment/opensearch-exporter-prometheus-elasticsearch-exporter \
  -n opensearch \
  --timeout=20m

echo "[OK] Monitoring ready"

echo
echo "[INFO] Waiting for exporter to authenticate..."

for i in {1..24}; do

    STATUS=$(sudo kubectl exec -n opensearch \
        deploy/opensearch-exporter-prometheus-elasticsearch-exporter \
        -- wget -qO- http://localhost:9108/metrics \
        | awk '/^elasticsearch_clusterinfo_up/{print $2}')

    if [ "$STATUS" = "1" ]; then
        echo "[OK] Exporter successfully connected to OpenSearch"
        break
    fi

    if [ "$i" -eq 24 ]; then
        echo "[ERROR] Exporter failed to authenticate with OpenSearch"
        exit 1
    fi

    sleep 5
done

sudo kubectl get servicemonitor \
  -n prometheus \
  opensearch-exporter-prometheus-elasticsearch-exporter \
  >/dev/null \
  || { echo "[ERROR] ServiceMonitor missing"; exit 1; }

echo "[OK] ServiceMonitor verified"

echo
echo "======================================================"
echo " OpenSearch Bootstrap Completed Successfully"
echo "======================================================"
echo
