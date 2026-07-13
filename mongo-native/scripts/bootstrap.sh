#!/usr/bin/env bash

set -euo pipefail

############################################################
#
# Shopixy MongoDB Production Bootstrap v2
#
############################################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

############################################################
# Colors
############################################################

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m'

############################################################
# Helpers
############################################################

section() {

    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="

}

log() {

    echo -e "${BLUE}[INFO]${NC} $1"

}

ok() {

    echo -e "${GREEN}[OK]${NC} $1"

}

warn() {

    echo -e "${YELLOW}[WARN]${NC} $1"

}

fail() {

    echo
    echo -e "${RED}[ERROR]${NC} $1"
    echo
    exit 1

}

success() {

    echo -e "${GREEN}[SUCCESS]${NC} $1"

}

############################################################
# Header
############################################################

echo
echo "=================================================="
echo " Shopixy MongoDB Production Bootstrap v2"
echo "=================================================="

############################################################
# Required Files
############################################################

section "Required Files"

REQUIRED_FILES=(

    ".env"

    "namespace.yaml"

    "mongo-headless-service.yaml"

    "mongo-service.yaml"

    "mongo-statefulset.yaml"

    "monitoring/mongodb-exporter-secret.yaml"

    "monitoring/mongodb-exporter-deployment.yaml"

    "monitoring/mongodb-exporter-service.yaml"

    "monitoring/mongodb-exporter-servicemonitor.yaml"

    "secrets/mongo-keyfile"

)

for FILE in "${REQUIRED_FILES[@]}"
do

    [ -f "$FILE" ] || fail "Missing required file: $FILE"

done

ok "Required files verified"

############################################################
# Dependencies
############################################################

section "Dependencies"

REQUIRED_BINS=(

    sudo
    kubectl
    base64

)

for BIN in "${REQUIRED_BINS[@]}"
do

    command -v "$BIN" >/dev/null 2>&1 \
        || fail "Missing dependency: $BIN"

done

ok "Dependencies verified"

############################################################
# Environment
############################################################

section "Environment"

set -a

source .env

set +a

: "${MONGO_NAMESPACE:?Missing MONGO_NAMESPACE}"

: "${MONGO_REPLICA_SET:?Missing MONGO_REPLICA_SET}"

: "${MONGO_ADMIN_USER:?Missing MONGO_ADMIN_USER}"

: "${MONGO_ADMIN_PASSWORD:?Missing MONGO_ADMIN_PASSWORD}"

: "${SHOPIXY_DB:?Missing SHOPIXY_DB}"

: "${SHOPIXY_USER:?Missing SHOPIXY_USER}"

: "${SHOPIXY_PASSWORD:?Missing SHOPIXY_PASSWORD}"

NAMESPACE="$MONGO_NAMESPACE"

ok "Environment loaded"

############################################################
# Namespace
############################################################

section "Namespace"

sudo kubectl apply \
    -f namespace.yaml

ok "Namespace ready"

############################################################
# Keyfile Secret
############################################################

section "Mongo Keyfile Secret"

sudo kubectl create secret generic mongo-keyfile \
    -n "$NAMESPACE" \
    --from-file=mongo-keyfile=secrets/mongo-keyfile \
    --dry-run=client -o yaml \
| sudo kubectl apply -f -

ok "mongo-keyfile secret ready"

############################################################
# Services
############################################################

section "Services"

sudo kubectl apply \
    -f mongo-headless-service.yaml

sudo kubectl apply \
    -f mongo-service.yaml

ok "Services ready"

############################################################
# MongoDB StatefulSet
############################################################

section "MongoDB Cluster"

sudo kubectl apply \
    -f mongo-statefulset.yaml

ok "StatefulSet applied"

############################################################
# Wait For StatefulSet
############################################################

section "Waiting For MongoDB"

sudo kubectl rollout status \
    statefulset/mongo \
    -n "$NAMESPACE" \
    --timeout=20m

ok "StatefulSet rollout completed"

############################################################
# Wait For Pods
############################################################

section "MongoDB Pods"

for POD in mongo-0 mongo-1 mongo-2
do

    echo "Waiting for ${POD}..."

    sudo kubectl wait \
        --for=condition=Ready \
        pod/${POD} \
        -n "$NAMESPACE" \
        --timeout=10m

done

ok "All MongoDB pods are Ready"

############################################################
# Wait For MongoDB
############################################################

section "MongoDB Readiness"

READY=false

for i in {1..60}
do

    if sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo --quiet \
        --eval "db.adminCommand({ ping: 1 }).ok" \
        >/dev/null 2>&1
    then

        READY=true
        break

    fi

    sleep 5

done

if [ "$READY" != "true" ]; then

    fail "MongoDB never became ready"

fi

ok "MongoDB is accepting connections"

############################################################
# Detect Cluster Mode
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

    CLUSTER_MODE="production"

else

    log "Authentication not available"

    CLUSTER_MODE="bootstrap"

fi

############################################################
# ReplicaSet
############################################################

section "ReplicaSet"

if [ "$CLUSTER_MODE" = "production" ]
then

    ok "ReplicaSet already managed"

else

    RS_STATUS=$(
    sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo --quiet \
        --eval "
            try{
                rs.status().ok
            }catch(e){
                print(0)
            }
        " \
    2>/dev/null \
    | tail -n1
    )

    if [ "$RS_STATUS" = "1" ]
    then

        ok "ReplicaSet already initialized"

    else

        log "Initializing ReplicaSet..."

        sudo kubectl exec \
            -n "$NAMESPACE" \
            mongo-0 \
            -- \
            mongo --quiet \
            --eval "
                rs.initiate({
                    _id:'$MONGO_REPLICA_SET',
                    members:[
                        {
                            _id:0,
                            host:'mongo-0.mongo-headless.$NAMESPACE.svc.cluster.local:27017'
                        },
                        {
                            _id:1,
                            host:'mongo-1.mongo-headless.$NAMESPACE.svc.cluster.local:27017'
                        },
                        {
                            _id:2,
                            host:'mongo-2.mongo-headless.$NAMESPACE.svc.cluster.local:27017'
                        }
                    ]
                })
            "

        ok "ReplicaSet initialized"

    fi

fi


############################################################
# Primary Election
############################################################

section "Primary Election"

PRIMARY=""

for i in {1..60}
do

    if [ "$CLUSTER_MODE" = "production" ]
    then

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
    --eval '
        var m = db.isMaster();

        if (m.primary) {
            print(m.primary);
        }
    ' \
2>/dev/null | tail -n1
)

    else

        PRIMARY=$(
sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo --quiet \
    --eval '
        var m = db.isMaster();

        if (m.primary) {
            print(m.primary);
        }
    ' \
2>/dev/null | tail -n1
)

    fi

    if [ -n "$PRIMARY" ] && [ "$PRIMARY" != "null" ]; then

        ok "Primary detected: $PRIMARY"
        break

    fi

    sleep 2

done

[ -n "$PRIMARY" ] \
|| fail "Primary not detected"

############################################################
# ReplicaSet Summary
############################################################

section "ReplicaSet Status"

if [ "$CLUSTER_MODE" = "production" ]
then

    sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "
            rs.status().members.forEach(function(m){
                print(
                    m.name+' -> '+m.stateStr
                )
            })
        "

else

    sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo --quiet \
        --eval "
            rs.status().members.forEach(function(m){
                print(
                    m.name+' -> '+m.stateStr
                )
            })
        "

fi

ok "ReplicaSet healthy"

############################################################
# Authentication
############################################################

section "Authentication"

if [ "$CLUSTER_MODE" = "production" ]
then

    AUTH_OK=$(
    sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "print(1)" \
    2>/dev/null \
    | tail -n1
    )

    [ "$AUTH_OK" = "1" ] \
    || fail "Admin authentication failed"

    ok "Admin authentication verified"

else

    ok "Authentication not enabled yet"

fi

############################################################
# Admin User
############################################################

section "Admin User"

if [ "$CLUSTER_MODE" = "production" ]; then

    ok "Admin user already exists"

else

    log "Creating admin user..."

    sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo admin \
        --quiet \
        --eval "
            db.createUser({
                user: '$MONGO_ADMIN_USER',
                pwd: '$MONGO_ADMIN_PASSWORD',
                roles: [
                    {
                        role: 'root',
                        db: 'admin'
                    }
                ]
            })
        "

    ok "Admin user created"

fi

############################################################
# Application User
############################################################

section "Application User"

if [ "$CLUSTER_MODE" = "production" ]; then

    ok "Application user already exists"

else

    log "Creating application user..."

    sudo kubectl exec \
        -n "$NAMESPACE" \
        mongo-0 \
        -- \
        mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "
            var appDb = db.getSiblingDB('$SHOPIXY_DB');

            appDb.createUser({
                user: '$SHOPIXY_USER',
                pwd: '$SHOPIXY_PASSWORD',
                roles: [
                    {
                        role: 'readWrite',
                        db: '$SHOPIXY_DB'
                    }
                ]
            });
        "

    ok "Application user created"

fi

############################################################
# Verify Application Login
############################################################

section "Application Authentication"

APP_AUTH=$(
sudo kubectl exec \
    -n "$NAMESPACE" \
    mongo-0 \
    -- \
    mongo "$SHOPIXY_DB" \
    -u "$SHOPIXY_USER" \
    -p "$SHOPIXY_PASSWORD" \
    --authenticationDatabase "$SHOPIXY_DB" \
    --quiet \
    --eval "print(db.runCommand({ping:1}).ok)" \
2>/dev/null \
| tail -n1
)

if [ "$APP_AUTH" != "1" ]
then
    fail "Application authentication failed"
fi

ok "Application authentication verified"

############################################################
# Monitoring
############################################################

section "Monitoring"

sudo kubectl apply \
    -f monitoring/mongodb-exporter-secret.yaml

sudo kubectl apply \
    -f monitoring/mongodb-exporter-deployment.yaml

sudo kubectl apply \
    -f monitoring/mongodb-exporter-service.yaml

sudo kubectl apply \
    -f monitoring/mongodb-exporter-servicemonitor.yaml

ok "Monitoring manifests applied"

############################################################
# Wait Exporter
############################################################

section "MongoDB Exporter"

sudo kubectl rollout status \
    deployment/mongodb-exporter \
    -n "$NAMESPACE" \
    --timeout=10m

ok "MongoDB Exporter Ready"

############################################################
# Verify Monitoring
############################################################

section "Monitoring Validation"

sudo kubectl get servicemonitor \
    mongodb-exporter \
    -n prometheus \
    >/dev/null \
|| fail "ServiceMonitor missing"

sudo kubectl get svc \
    mongodb-exporter \
    -n "$NAMESPACE" \
    >/dev/null \
|| fail "Exporter Service missing"

ok "Monitoring verified"

############################################################
# Persistent Volumes
############################################################

section "Persistent Volumes"

PVCS=$(
sudo kubectl get pvc \
    -n "$NAMESPACE" \
    --no-headers \
| grep mongo \
| wc -l
)

if [ "$PVCS" -lt 3 ]
then
    fail "Expected 3 PVCs"
fi

ok "Persistent Volumes verified"

############################################################
# Cluster Summary
############################################################

section "Cluster Summary"

echo ""
sudo kubectl get statefulset -n "$NAMESPACE"

echo ""
sudo kubectl get pods -n "$NAMESPACE" -o wide

echo ""
sudo kubectl get svc -n "$NAMESPACE"


ok "Cluster summary completed"


############################################################
# Final Summary
############################################################

echo
echo "=================================================="
echo " MongoDB Bootstrap Completed Successfully"
echo "=================================================="
echo

success "Namespace ................. READY"
success "Secrets ................... READY"
success "StatefulSet ............... READY"
success "ReplicaSet ............... READY"
success "Primary ................... READY"
success "Authentication ........... READY"
success "Application User ......... READY"
success "Services ................. READY"
success "Exporter ................. READY"
success "Monitoring ............... READY"
success "Persistent Volumes ....... READY"

echo
echo "Production Status : READY"
echo
