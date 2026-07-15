#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

############################################################
# Header
############################################################

clear

echo
echo "======================================================"
echo "      Shopixy Infrastructure Master Bootstrap"
echo "======================================================"
echo

############################################################
# Make All Scripts Executable
############################################################

echo "[INFO] Making all shell scripts executable..."

find "$PROJECT_ROOT" \
    -type f \
    -name "*.sh" \
    -exec chmod +x {} \;

echo "[OK] Shell scripts verified"
echo

############################################################
# Helper
############################################################

run_stack() {

    local NAME="$1"
    local DIR="$2"
    local SCRIPT="$3"

    echo
    echo "======================================================"
    echo " ${NAME}"
    echo "======================================================"
    echo

    cd "$PROJECT_ROOT/$DIR"

    "./$SCRIPT"

    echo
    echo "[OK] ${NAME} Completed"
}

############################################################
# Bootstrap Order
############################################################

run_stack "Cert Manager" \
    "cert-manager" \
    "bootstrap.sh"

run_stack "MetalLB" \
    "metallb" \
    "bootstrap.sh"

run_stack "Traefik" \
    "traefik" \
    "bootstrap.sh"

run_stack "Firewall" \
    "firewall" \
    "bootstrap.sh"

run_stack "MinIO" \
    "minio" \
    "bootstrap.sh"

run_stack "PostgreSQL" \
    "postgresql" \
    "bootstrap.sh"

run_stack "Prometheus" \
    "prometheus" \
    "bootstrap.sh"

run_stack "MongoDB" \
    "mongo-native/scripts" \
    "bootstrap.sh"

run_stack "RabbitMQ" \
    "rabbitmq" \
    "bootstrap.sh"

run_stack "Redis" \
    "redis/scripts" \
    "bootstrap.sh"

run_stack "OpenSearch" \
    "opensearch" \
    "bootstrap.sh"

run_stack "Grafana" \
    "grafana" \
    "bootstrap.sh"

run_stack "Network Policies" \
    "network-policies" \
    "bootstrap.sh"

############################################################
# Done
############################################################

echo
echo "======================================================"
echo " Infrastructure Bootstrap Completed Successfully"
echo "======================================================"
echo
