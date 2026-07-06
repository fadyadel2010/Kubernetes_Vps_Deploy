#!/usr/bin/env bash

set -Eeuo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo
echo "======================================================"
echo "      Shopixy Network Policies Bootstrap"
echo "======================================================"
echo

##################################################
# Dependencies
##################################################

for BIN in kubectl
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "[ERROR] Missing dependency: $BIN"
        exit 1
    fi
done

##################################################
# Required Files
##################################################

REQUIRED_FILES=(
    "default-deny/minio.yaml"
    "default-deny/mongo.yaml"
    "default-deny/opensearch.yaml"
    "default-deny/postgresql.yaml"
    "default-deny/prometheus.yaml"
    "default-deny/rabbitmq.yaml"
    "default-deny/redis.yaml"
    "default-deny/traefik.yaml"
    "policies/grafana.yaml"
    "policies/minio.yaml"
    "policies/mongo.yaml"
    "policies/mongodb-exporter.yaml"
    "policies/opensearch.yaml"
    "policies/opensearch-exporter.yaml"
    "policies/postgresql.yaml"
    "policies/postgresql-prometheus.yaml"
    "policies/prometheus.yaml"
    "policies/rabbitmq.yaml"
    "policies/redis.yaml"
    "policies/redis-prometheus.yaml"
    "policies/traefik.yaml"
)

for FILE in "${REQUIRED_FILES[@]}"
do
    if [ ! -f "$SCRIPT_DIR/$FILE" ]
    then
        echo "[ERROR] Missing file: $FILE"
        exit 1
    fi
done

echo "[OK] Bootstrap files verified"

##################################################
# Default Deny Policies
##################################################

echo
echo "=== Applying Default Deny Policies ==="

for FILE in "$SCRIPT_DIR"/default-deny/*.yaml
do
    echo "Applying $(basename "$FILE")..."

    $KUBECTL apply -f "$FILE"
done

##################################################
# Stack Policies
##################################################

echo
echo "=== Applying Stack Policies ==="

for FILE in "$SCRIPT_DIR"/policies/*.yaml
do
    echo "Applying $(basename "$FILE")..."

    $KUBECTL apply -f "$FILE"
done

##################################################
# Summary
##################################################

echo
echo "=== Installed Network Policies ==="

$KUBECTL get networkpolicy -A

echo
echo "======================================================"
echo " Network Policies Bootstrap Completed Successfully"
echo "======================================================"
echo
