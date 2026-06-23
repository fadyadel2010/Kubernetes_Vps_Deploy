#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/scripts/common.sh"

NAMESPACE="opensearch"

log_info "Configuring Backup Infrastructure"

#
# S3 Credentials Secret
#

log_info "Applying S3 credentials secret"

sudo kubectl apply \
  -f "${ROOT_DIR}/snapshots/minio-s3-secret.yaml"

log_ok "S3 credentials secret ready"

#
# Snapshot Job Secret
#

log_info "Applying snapshot job secret"

sudo kubectl apply \
  -f "${ROOT_DIR}/snapshots/snapshot-secret.yaml"

log_ok "Snapshot job secret ready"

#
# Snapshot CronJob
#

log_info "Applying snapshot CronJob"

sudo kubectl apply \
  -f "${ROOT_DIR}/snapshots/snapshot-cronjob.yaml"

log_ok "Snapshot CronJob ready"

#
# Verify Resources
#

sudo kubectl get secret \
  opensearch-s3-credentials \
  -n "$NAMESPACE" >/dev/null

sudo kubectl get secret \
  opensearch-snapshot-job \
  -n "$NAMESPACE" >/dev/null

sudo kubectl get cronjob \
  opensearch-snapshot \
  -n "$NAMESPACE" >/dev/null

#
# Verify Snapshot Repository
#

OS_USER=$(
  sudo kubectl get secret opensearch-snapshot-job \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.OS_USER}' | base64 -d
)

OS_PASS=$(
  sudo kubectl get secret opensearch-snapshot-job \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.OS_PASS}' | base64 -d
)

OPENSEARCH_POD=$(
  sudo kubectl get pod \
    -n "$NAMESPACE" \
    -l opensearch.org/opensearch-cluster=shopixy-search \
    -o jsonpath='{.items[0].metadata.name}'
)

REPO_CODE=$(
  sudo kubectl exec \
    -n "$NAMESPACE" \
    "$OPENSEARCH_POD" \
    -- curl -sk \
      -u "$OS_USER:$OS_PASS" \
      https://localhost:9200/_snapshot/shopixy-snapshots \
      -o /dev/null \
      -w "%{http_code}"
)

if [ "$REPO_CODE" = "200" ]
then
  log_ok "Snapshot repository verified"
else
  log_error "Snapshot repository verification failed (HTTP $REPO_CODE)"
  exit 1
fi
