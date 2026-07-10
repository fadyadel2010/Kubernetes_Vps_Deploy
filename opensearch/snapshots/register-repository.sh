#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"
echo
echo "======================================"
echo " Register Snapshot Repository"
echo "======================================"
OS_PASS=$($KUBECTL get secret shopixy-search-admin-password \
  -n opensearch \
  -o jsonpath='{.data.password}' | base64 -d)
POD=$($KUBECTL get pod \
  -n opensearch \
  -l opensearch.org/opensearch-cluster=shopixy-search \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
    echo "[ERROR] No running OpenSearch pod found"
    exit 1
fi
echo "[INFO] Using pod: $POD"
cat >/tmp/repository.json <<EOF
{
  "type":"s3",
  "settings":{
    "bucket":"opensearch-snapshots",
    "endpoint":"http://minio.minio.svc.cluster.local:9000",
    "protocol":"http",
    "path_style_access":"true"
  }
}
EOF
$KUBECTL cp /tmp/repository.json \
  opensearch/${POD}:/tmp/repository.json
echo "[INFO] Checking snapshot repository..."
EXISTS=$($KUBECTL exec -n opensearch "$POD" -- \
curl -sk \
-u admin:${OS_PASS} \
https://localhost:9200/_snapshot/shopixy-snapshots)
if echo "$EXISTS" | jq -e '."shopixy-snapshots"' >/dev/null 2>&1
then
    echo "[SKIP] Snapshot repository already exists"
else
    echo "[INFO] Registering snapshot repository..."

    RESPONSE=$($KUBECTL exec -n opensearch "$POD" -- \
    curl -sk \
    -u admin:${OS_PASS} \
    -X PUT \
    -H "Content-Type: application/json" \
    https://localhost:9200/_snapshot/shopixy-snapshots \
    -d @/tmp/repository.json)

    echo "$RESPONSE"

    if echo "$RESPONSE" | jq -e '.acknowledged == true' >/dev/null 2>&1
    then
        echo "[OK] Snapshot repository created"
    else
        echo "[ERROR] Failed to create snapshot repository"
        exit 1
    fi
fi
echo "[INFO] Verifying repository..."

VERIFY=$($KUBECTL exec -n opensearch "$POD" -- \
curl -sk \
-u admin:${OS_PASS} \
-X POST \
https://localhost:9200/_snapshot/shopixy-snapshots/_verify?pretty)

echo "$VERIFY"

if echo "$VERIFY" | jq -e '.nodes' >/dev/null 2>&1
then
    echo "[OK] Snapshot repository verified"
else
    echo "[ERROR] Snapshot repository verification failed"
    exit 1
fi

echo
echo "[OK] Snapshot repository registered successfully"
