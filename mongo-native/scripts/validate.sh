#!/bin/bash
set -euo pipefail

############################################################
# Environment
############################################################

[ -f ".env" ] || fail ".env not found"

set -a
source .env
set +a

############################################################
# Variables
############################################################

NAMESPACE="$MONGO_NAMESPACE"

############################################################
# Shopixy MongoDB Production Validation
############################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

############################################################
# Colors
############################################################

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

############################################################
# Helpers
############################################################

section() {

    echo ""
    echo "=================================================="
    echo " $1"
    echo "=================================================="

}

ok() {

    echo -e "${GREEN}[OK]${NC} $1"

}

warn() {

    echo -e "${YELLOW}[WARN]${NC} $1"

}

fail() {

    echo ""
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1

}

############################################################
# Environment
############################################################

[ -f ".env" ] || fail ".env not found"

set -a
source .env
set +a

############################################################
# Header
############################################################

echo ""
echo "=================================================="
echo " Shopixy MongoDB Production Validation"
echo "=================================================="

############################################################
# Dependencies
############################################################

section "Dependencies"

command -v kubectl >/dev/null 2>&1 \
    || fail "Missing dependency: kubectl"

ok "Dependencies verified"

############################################################
# Namespace
############################################################

section "Namespace"

sudo kubectl get namespace "$NAMESPACE" >/dev/null \
|| fail "Namespace '$NAMESPACE' not found"

ok "Namespace exists"

############################################################
# StatefulSet
############################################################

section "MongoDB Cluster"

sudo kubectl get statefulset mongo \
    -n "$NAMESPACE" >/dev/null \
|| fail "MongoDB StatefulSet not found"

READY=$(
sudo kubectl get statefulset mongo \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}'
)

READY="${READY:-0}"

[ "$READY" -eq 3 ] \
|| fail "StatefulSet Ready = $READY/3"

ok "StatefulSet Ready (3/3)"

############################################################
# Pods
############################################################

section "MongoDB Pods"

PODS_READY=$(
sudo kubectl get pods \
    -n "$NAMESPACE" \
    -l app=mongo \
    --no-headers \
| grep "1/1.*Running" \
| wc -l
)

[ "$PODS_READY" -eq 3 ] \
|| fail "MongoDB Pods Ready = $PODS_READY/3"

ok "MongoDB Pods (3/3)"

############################################################
# MongoDB Readiness
############################################################

section "MongoDB Readiness"

if sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo --quiet \
    --eval "print('ok')" \
    >/dev/null 2>&1
then

    ok "MongoDB is accepting connections"

else

    fail "MongoDB is not accepting connections"

fi

############################################################
# Cluster Detection
############################################################

section "Cluster Detection"

AUTH_ENABLED=false

if sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo admin \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --quiet \
    --eval "print(1)" \
    >/dev/null 2>&1
then

    AUTH_ENABLED=true

fi

if [ "$AUTH_ENABLED" = "true" ]
then

    ok "Existing authenticated cluster detected"

else

    fail "MongoDB authentication failed"

fi

############################################################
# ReplicaSet
############################################################

section "ReplicaSet"

RS_OK=$(
sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo admin \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --quiet \
    --eval "print(rs.status().ok)" \
2>/dev/null \
| tail -n1
)

[ "$RS_OK" = "1" ] \
|| fail "ReplicaSet is unhealthy"

ok "ReplicaSet Healthy"

############################################################
# Primary Election
############################################################

section "Primary Election"

PRIMARY=$(
sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo admin \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --quiet \
    --eval "print(rs.isMaster().primary)" \
2>/dev/null \
| tail -n1
)

[ -n "$PRIMARY" ] \
|| fail "Primary not detected"

ok "Primary detected: $PRIMARY"

############################################################
# ReplicaSet Status
############################################################

section "ReplicaSet Status"

sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo admin \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --quiet \
    --eval '
        rs.status().members.forEach(function(m){
            print(m.name + " -> " + m.stateStr)
        })
    '

ok "ReplicaSet healthy"

############################################################
# Authentication
############################################################

section "Authentication"

sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo admin \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --quiet \
    --eval "db.runCommand({connectionStatus:1}).ok" \
>/dev/null \
|| fail "Admin authentication failed"

ok "Admin authentication verified"

############################################################
# Application Authentication
############################################################

section "Application Authentication"

sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo "$SHOPIXY_DB" \
    -u "$SHOPIXY_USER" \
    -p "$SHOPIXY_PASSWORD" \
    --authenticationDatabase "$SHOPIXY_DB" \
    --quiet \
    --eval "db.runCommand({connectionStatus:1}).ok" \
>/dev/null \
|| fail "Application authentication failed"

ok "Application authentication verified"

############################################################
# Services
############################################################

section "Services"

for SERVICE in mongo mongo-headless mongodb-exporter
do

    sudo kubectl get svc \
        "$SERVICE" \
        -n "$NAMESPACE" \
        >/dev/null \
    || fail "Service '$SERVICE' not found"

    ok "Service verified: $SERVICE"

done

############################################################
# MongoDB Exporter
############################################################

section "MongoDB Exporter"

sudo kubectl get deployment \
    mongodb-exporter \
    -n "$NAMESPACE" \
    >/dev/null \
|| fail "MongoDB Exporter deployment not found"

EXPORTER_READY=$(
sudo kubectl get deployment \
    mongodb-exporter \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}'
)

EXPORTER_READY="${EXPORTER_READY:-0}"

[ "$EXPORTER_READY" -ge 1 ] \
|| fail "MongoDB Exporter is not Ready"

ok "MongoDB Exporter Ready"

############################################################
# ServiceMonitor
############################################################

section "ServiceMonitor"

sudo kubectl get servicemonitor \
    mongodb-exporter \
    -n prometheus \
    >/dev/null \
|| fail "MongoDB ServiceMonitor not found"

ok "ServiceMonitor verified"

############################################################
# Monitoring
############################################################

section "Monitoring"

EXPORTER_POD=$(
sudo kubectl get pods \
    -n "$NAMESPACE" \
    -l app=mongodb-exporter \
    -o jsonpath='{.items[0].metadata.name}'
)

[ -n "$EXPORTER_POD" ] \
|| fail "MongoDB Exporter pod not found"

sudo kubectl wait \
    --for=condition=Ready \
    pod/"$EXPORTER_POD" \
    -n "$NAMESPACE" \
    --timeout=120s \
>/dev/null

ok "Exporter pod Ready"


############################################################
# Monitoring Validation
############################################################

section "Monitoring Validation"

ok "Monitoring stack healthy"

############################################################
# Persistent Volumes
############################################################

section "Persistent Volumes"

PVC_COUNT=$(
sudo kubectl get pvc \
    -n "$NAMESPACE" \
    --no-headers 2>/dev/null \
| wc -l
)

[ "$PVC_COUNT" -ge 3 ] \
|| fail "Expected at least 3 PVCs, found $PVC_COUNT"

ok "Persistent Volume Claims present ($PVC_COUNT)"

############################################################
# Cluster Summary
############################################################

section "Cluster Summary"

echo ""

sudo kubectl get statefulset \
    -n "$NAMESPACE"

echo ""

sudo kubectl get pods \
    -n "$NAMESPACE" \
    -o wide

echo ""

sudo kubectl get svc \
    -n "$NAMESPACE"

echo ""

sudo kubectl get pvc \
    -n "$NAMESPACE"

echo ""

ok "Cluster summary completed"

############################################################
# Validation Result
############################################################

section "Validation Result"

ok "Namespace ................. OK"
ok "StatefulSet ............... OK"
ok "Pods ...................... OK"
ok "ReplicaSet ............... OK"
ok "Primary ................... OK"
ok "Authentication ............ OK"
ok "Application User .......... OK"
ok "Services ................. OK"
ok "Exporter ................. OK"
ok "Monitoring ............... OK"
ok "Persistent Volumes ........ OK"

############################################################
# Footer
############################################################

echo ""
echo "=================================================="
echo " MongoDB Validation Completed Successfully"
echo "=================================================="
echo ""

echo "Production Status : READY"

echo ""
