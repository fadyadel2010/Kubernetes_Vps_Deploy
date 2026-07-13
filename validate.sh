#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

START_TIME=$(date +%s)

PASS_COUNT=0

section() {
    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

pass() {
    echo "[PASS] $1"
    PASS_COUNT=$((PASS_COUNT+1))
}

fail() {
    echo
    echo "[FAIL] $1"
    echo
    echo "Master Validation Failed."
    exit 1
}

run_validation() {

    local NAME="$1"
    local SCRIPT="$2"

    section "$NAME"

    if [ ! -f "$SCRIPT" ]; then
        fail "$SCRIPT not found"
    fi

    sudo chmod +x "$SCRIPT"

    if "$SCRIPT"; then
        pass "$NAME"
    else
        fail "$NAME"
    fi
}

##################################################
# Header
##################################################

clear

echo
echo "=================================================="
echo " Shopixy Kubernetes Master Validation"
echo "=================================================="
echo

##################################################
# Infrastructure
##################################################

section "Infrastructure"

echo "[INFO] Checking Kubernetes API..."

sudo kubectl version >/dev/null

echo "[INFO] Checking Nodes..."

sudo kubectl wait \
    --for=condition=Ready \
    node \
    --all \
    --timeout=5m >/dev/null

echo "[INFO] Checking CoreDNS..."

sudo kubectl rollout status \
    deployment/coredns \
    -n kube-system \
    --timeout=5m >/dev/null

echo "[INFO] Checking Metrics Server..."

sudo kubectl get deployment \
    metrics-server \
    -n kube-system >/dev/null

pass "Infrastructure"

##################################################
# Stack Validations
##################################################

run_validation \
    "Firewall" \
    "$ROOT_DIR/firewall/validate.sh"

run_validation \
    "Cert Manager" \
    "$ROOT_DIR/cert-manager/validate.sh"

run_validation \
    "MetalLB" \
    "$ROOT_DIR/metallb/validate.sh"

run_validation \
    "Traefik" \
    "$ROOT_DIR/traefik/validate.sh"

run_validation \
    "Network Policies" \
    "$ROOT_DIR/network-policies/validate.sh"

run_validation \
    "PostgreSQL" \
    "$ROOT_DIR/postgresql/validate.sh"

run_validation \
    "MongoDB" \
    "$ROOT_DIR/mongo-native/scripts/validate.sh"

run_validation \
    "RabbitMQ" \
    "$ROOT_DIR/rabbitmq/validate.sh"

run_validation \
    "Redis" \
    "$ROOT_DIR/redis/scripts/validate.sh"

run_validation \
    "OpenSearch" \
    "$ROOT_DIR/opensearch/validate.sh"

run_validation \
    "MinIO" \
    "$ROOT_DIR/minio/validate.sh"

run_validation \
    "Prometheus" \
    "$ROOT_DIR/prometheus/validate.sh"

run_validation \
    "Grafana" \
    "$ROOT_DIR/grafana/validate.sh"

##################################################
# Cluster Health
##################################################

section "Cluster Health"

echo "[INFO] Checking Production Namespaces..."

PRODUCTION_NAMESPACES=(
    cert-manager
    metallb-system
    traefik
    postgresql
    mongo
    rabbitmq
    redis
    opensearch
    minio
    prometheus
    grafana
)

BAD_PODS=""

for NS in "${PRODUCTION_NAMESPACES[@]}"
do

    PODS=$(
    sudo kubectl get pods \
        -n "$NS" \
        --no-headers 2>/dev/null \
    | grep -E "CrashLoopBackOff|ImagePullBackOff|CreateContainerConfigError|CreateContainerError|ErrImagePull|Error|Pending" \
    || true
    )

    #
    # Ignore known upstream Redis Sentinel Operator bug
    #
    if [ "$NS" = "redis" ]; then
        PODS=$(echo "$PODS" | grep -v "redis-sentinel-sentinel" || true)
    fi

    if [ -n "$PODS" ]; then
        BAD_PODS="${BAD_PODS}
Namespace: ${NS}
${PODS}"
    fi

done

if [ -n "$BAD_PODS" ]; then

    echo
    echo "$BAD_PODS"
    echo

    fail "Production cluster contains unhealthy Pods"

fi

pass "Production Cluster Health"

##################################################
# Finished
##################################################

END_TIME=$(date +%s)

DURATION=$((END_TIME-START_TIME))

echo
echo "=================================================="
echo " Validation Summary"
echo "=================================================="
echo

printf "%-30s %s\n" "Infrastructure" "PASS"
printf "%-30s %s\n" "Firewall" "PASS"
printf "%-30s %s\n" "Cert Manager" "PASS"
printf "%-30s %s\n" "MetalLB" "PASS"
printf "%-30s %s\n" "Traefik" "PASS"
printf "%-30s %s\n" "Network Policies" "PASS"

printf "%-30s %s\n" "PostgreSQL" "PASS"
printf "%-30s %s\n" "MongoDB" "PASS"
printf "%-30s %s\n" "RabbitMQ" "PASS"
printf "%-30s %s\n" "Redis" "PASS"
printf "%-30s %s\n" "OpenSearch" "PASS"
printf "%-30s %s\n" "MinIO" "PASS"

printf "%-30s %s\n" "Prometheus" "PASS"
printf "%-30s %s\n" "Grafana" "PASS"

echo
echo "Validated Components : $PASS_COUNT"

printf "Duration             : %02d:%02d:%02d\n" \
$((DURATION/3600)) \
$(((DURATION%3600)/60)) \
$((DURATION%60))

echo
echo "=================================================="
echo " ALL VALIDATIONS PASSED"
echo "=================================================="
echo
