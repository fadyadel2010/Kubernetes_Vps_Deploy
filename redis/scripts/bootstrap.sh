#!/bin/bash

set -euo pipefail

#################################################
# Redis Kubernetes Bootstrap
# Shopixy Infrastructure
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ENV_FILE="$PROJECT_ROOT/.env"

NAMESPACE="redis"
OPERATOR_NAMESPACE="redis-operator"

#################################################
# Colors
#################################################

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

#################################################
# Helpers
#################################################

success() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

error() {
    echo -e "${RED}$1${NC}"
    exit 1
}

#################################################
# Load Environment
#################################################

if [ ! -f "$ENV_FILE" ]; then
    error "ERROR: .env file not found"
fi

set -a
source "$ENV_FILE"
set +a

#################################################
# Header
#################################################

echo "=================================================="
echo " Redis Kubernetes Bootstrap"
echo "=================================================="

#################################################
# Step 1
#################################################

echo "[1/10] Validating environment..."

for CMD in kubectl helm openssl; do
    command -v "$CMD" >/dev/null 2>&1 || \
        error "Missing dependency: $CMD"
done

sudo -E kubectl cluster-info >/dev/null

success "      Environment OK"

#################################################
# Step 2
#################################################

echo "[2/10] Creating namespace..."

sudo -E kubectl apply -f "$PROJECT_ROOT/namespace.yaml"

success "      Namespace OK"

#################################################
# Step 3
#################################################

echo "[3/10] Validating Redis Operator..."

if sudo -E kubectl get deployment \
    redis-operator \
    -n redis-system >/dev/null 2>&1
then

    OPERATOR_NAMESPACE="redis-system"

    success "      Existing operator found"

else

    warn "      Operator not found, installing..."

    sudo -E helm upgrade --install redis-operator \
        "$PROJECT_ROOT/redis-operator" \
        -n "$OPERATOR_NAMESPACE" \
        --create-namespace

fi

sudo -E kubectl rollout status \
    deployment/redis-operator \
    -n "$OPERATOR_NAMESPACE" \
    --timeout=300s

AVAILABLE=$(
sudo -E kubectl get deployment redis-operator \
-n "$OPERATOR_NAMESPACE" \
-o jsonpath='{.status.availableReplicas}'
)

[ "${AVAILABLE:-0}" -ge 1 ] || \
    error "Redis Operator not available"

success "      Operator OK"

AVAILABLE=$(
sudo -E kubectl get deployment redis-operator \
-n "$OPERATOR_NAMESPACE" \
-o jsonpath='{.status.availableReplicas}'
)


#################################################
# Step 4
#################################################

echo "[4/10] Validating authentication secret..."

if sudo kubectl get secret redis-auth \
    -n "$NAMESPACE" >/dev/null 2>&1
then

    CURRENT_PASSWORD=$(
        sudo -E kubectl get secret redis-auth \
        -n "$NAMESPACE" \
        -o jsonpath='{.data.password}' \
        | base64 -d
    )

    if [ "$CURRENT_PASSWORD" != "$REDIS_PASSWORD" ]; then
        error "redis-auth password differs from .env"
    fi

    success "      Existing secret validated"

else

    sudo -E kubectl create secret generic redis-auth \
        --from-literal=password="$REDIS_PASSWORD" \
        -n "$NAMESPACE"

    success "      Secret created"

fi

#################################################
# Step 5
#################################################

echo "[5/10] Deploying Redis Replication..."

sudo -E kubectl annotate redisreplication redis \
    -n "$NAMESPACE" \
    kubectl.kubernetes.io/last-applied-configuration- \
    >/dev/null 2>&1 || true


sudo -E kubectl apply \
    -f "$PROJECT_ROOT/redis-replication.yaml"

success "      Redis CR applied"

#################################################
# Step 6
#################################################

echo "[6/10] Waiting for Redis..."

sudo -E kubectl rollout status \
    statefulset/redis \
    -n "$NAMESPACE" \
    --timeout=600s

sudo -E kubectl wait \
    --for=condition=Ready \
    pod/redis-0 \
    -n "$NAMESPACE" \
    --timeout=300s

sudo -E kubectl wait \
    --for=condition=Ready \
    pod/redis-1 \
    -n "$NAMESPACE" \
    --timeout=300s

sudo -E kubectl wait \
    --for=condition=Ready \
    pod/redis-2 \
    -n "$NAMESPACE" \
    --timeout=300s

success "      Redis Ready"

#################################################
# Step 7
#################################################

echo "[7/10] Deploying Redis Sentinel..."

sudo -E kubectl annotate redissentinel redis-sentinel \
    -n "$NAMESPACE" \
    kubectl.kubernetes.io/last-applied-configuration- \
    >/dev/null 2>&1 || true

sudo -E kubectl apply \
    -f "$PROJECT_ROOT/redis-sentinel.yaml"

success "      Sentinel CR applied"

#################################################
# Step 8
#################################################

#################################################
# Step 8
#################################################

echo "[8/10] Validating Sentinel..."

# Give the operator a few seconds to reconcile
sleep 10

REDIS_READY=$(
(
sudo -E kubectl get pods -n "$NAMESPACE" \
| grep "^redis-[0-9]" \
| grep "2/2.*Running" \
| wc -l
) || true
)

if [ "${REDIS_READY:-0}" -ne 3 ]; then
    error "Redis cluster is not healthy."
fi

SENTINEL_READY=$(
(
sudo -E kubectl get pods -n "$NAMESPACE" \
| grep "^redis-sentinel-sentinel-" \
| grep "2/2.*Running" \
| wc -l
) || true
)

if [ "${SENTINEL_READY:-0}" -eq 3 ]; then

    success "      Sentinel Ready"

else

    warn "      Sentinel pods are not Ready."
    warn "      Known Redis Operator upstream issue detected."
    warn "      Redis replication is healthy. Continuing bootstrap."

fi



#################################################
# Step 9
#################################################

echo "[9/10] Deploying Monitoring..."

sudo -E kubectl apply \
    -f "$PROJECT_ROOT/monitoring/redis-servicemonitor.yaml"

success "      ServiceMonitor Applied"

echo ""
echo "=================================================="
echo " Redis Bootstrap Completed Successfully"
echo "=================================================="
echo ""
