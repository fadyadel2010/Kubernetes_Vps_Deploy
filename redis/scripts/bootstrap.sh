#!/bin/bash

set -eo pipefail

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

[ "${AVAILABLE:-0}" -ge 1 ] || \
    error "Redis Operator not available"

success "      Operator OK"

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

sudo -E kubectl apply \
    -f "$PROJECT_ROOT/redis-sentinel.yaml"

success "      Sentinel CR applied"

#################################################
# Step 8
#################################################

echo "[8/10] Waiting for Sentinel..."

sudo -E kubectl rollout status \
    statefulset/redis-sentinel-sentinel \
    -n "$NAMESPACE" \
    --timeout=600s

sudo -E kubectl wait \
    --for=condition=Ready \
    pod/redis-sentinel-sentinel-0 \
    -n "$NAMESPACE" \
    --timeout=300s

sudo -E kubectl wait \
    --for=condition=Ready \
    pod/redis-sentinel-sentinel-1 \
    -n "$NAMESPACE" \
    --timeout=300s

sudo -E kubectl wait \
    --for=condition=Ready \
    pod/redis-sentinel-sentinel-2 \
    -n "$NAMESPACE" \
    --timeout=300s

success "      Sentinel Ready"

#################################################
# Step 9
#################################################

echo "[9/10] Deploying Monitoring..."

sudo -E kubectl apply \
    -f "$PROJECT_ROOT/monitoring/redis-servicemonitor.yaml"

success "      ServiceMonitor Applied"

#################################################
# Step 10
#################################################

echo "[10/10] Running Production Validation..."

#################################################
# Authentication
#################################################

AUTH_FAIL=$(
sudo -E kubectl exec -n "$NAMESPACE" redis-0 -- \
redis-cli ping 2>&1 || true
)

echo "$AUTH_FAIL" | grep -q "NOAUTH" || \
    error "Authentication validation failed"

AUTH_OK=$(
sudo -E kubectl exec -n "$NAMESPACE" redis-0 -- \
env REDISCLI_AUTH="$REDIS_PASSWORD" \
redis-cli --no-auth-warning ping
)

echo "$AUTH_OK" | grep -q "PONG" || \
    error "Authenticated ping failed"

success "      Authentication OK"

#################################################
# Replication
#################################################

REPLICATION_INFO=$(
sudo -E kubectl exec -n "$NAMESPACE" redis-0 -- \
env REDISCLI_AUTH="$REDIS_PASSWORD" \
redis-cli --no-auth-warning INFO replication
)

ROLE=$(
echo "$REPLICATION_INFO" \
| grep '^role:' \
| cut -d: -f2 \
| tr -d '\r'
)

[ "$ROLE" = "master" ] || \
    error "redis-0 is not master"

SLAVES=$(
echo "$REPLICATION_INFO" \
| grep '^connected_slaves:' \
| cut -d: -f2 \
| tr -d '\r'
)

[ "${SLAVES:-0}" -ge 2 ] || \
    error "Expected >=2 replicas, found $SLAVES"

success "      Replication OK"

#################################################
# Sentinel
#################################################

sleep 15

SENTINEL_INFO=$(
sudo -E kubectl exec -n "$NAMESPACE" \
redis-sentinel-sentinel-0 -- \
redis-cli -p 26379 SENTINEL master mymaster
)

echo "$SENTINEL_INFO" | grep -q "master" || \
    error "Sentinel master validation failed"

# redis-cli prints array replies with index prefixes and quotes, e.g.:
#   31) "num-slaves"
#   32) "2"
# so we split on '"' after the getline to pull out just the value.
NUM_SLAVES=$(
echo "$SENTINEL_INFO" |
awk '/^num-slaves$/ {getline; print}' |
tr -dc '0-9'
)

NUM_SENTINELS=$(
echo "$SENTINEL_INFO" |
awk '/^num-other-sentinels$/ {getline; print}' |
tr -dc '0-9'
)

echo "      Sentinel replicas: $NUM_SLAVES"
echo "      Other sentinels : $NUM_SENTINELS"

[ "${NUM_SLAVES:-0}" -ge 2 ] || \
    error "Sentinel sees less than 2 replicas"

[ "${NUM_SENTINELS:-0}" -ge 2 ] || \
    error "Sentinel quorum not formed"

success "      Sentinel OK"

#################################################
# Monitoring
#################################################

sudo -E kubectl get servicemonitor \
redis-servicemonitor \
-n "$NAMESPACE" >/dev/null 2>&1 || \
error "ServiceMonitor missing"

success "      Monitoring OK"

#################################################
# Summary
#################################################

echo ""
echo "=================================================="
echo " Redis Bootstrap Completed Successfully"
echo "=================================================="
echo ""

success "Operator ................. OK"
success "Authentication ........... OK"
success "Replication .............. OK"
success "Sentinel ................. OK"
success "Monitoring ............... OK"

echo ""
echo "Redis Production Stack Ready"
echo "=================================================="
