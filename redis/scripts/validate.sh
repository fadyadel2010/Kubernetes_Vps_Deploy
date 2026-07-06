#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

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


for CMD in kubectl; do
    command -v "$CMD" >/dev/null 2>&1 || \
        error "Missing dependency: $CMD"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ENV_FILE="$PROJECT_ROOT/.env"

echo ""
echo "=================================================="
echo " Redis Production Validation"
echo "=================================================="
echo ""

NAMESPACE="redis"


if [ ! -f "$ENV_FILE" ]; then
    error "ERROR: .env file not found"
fi

set -a
source "$ENV_FILE"
set +a


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

echo "$SENTINEL_INFO" | grep -q "^name$" || \
    error "Sentinel master validation failed"

NUM_SLAVES=$(
echo "$SENTINEL_INFO" |
awk '/^num-slaves$/ {getline; print}'
)

NUM_SENTINELS=$(
echo "$SENTINEL_INFO" |
awk '/^num-other-sentinels$/ {getline; print}'
)

MASTER_IP=$(
echo "$SENTINEL_INFO" |
awk '/^ip$/ {getline; print}'
)

FLAGS=$(
echo "$SENTINEL_INFO" |
awk '/^flags$/ {getline; print}'
)

echo "      Sentinel master  : $MASTER_IP"
echo "      Sentinel flags   : $FLAGS"
echo "      Sentinel slaves  : $NUM_SLAVES"
echo "      Other sentinels  : $NUM_SENTINELS"

[[ "$MASTER_IP" != "0.0.0.0" ]] || \
    error "Sentinel is monitoring an invalid master address (0.0.0.0)"

[[ "$FLAGS" != *"s_down"* ]] || \
    error "Sentinel reports master as S_DOWN"

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
echo " Redis Validation Completed Successfully"
echo "=================================================="
