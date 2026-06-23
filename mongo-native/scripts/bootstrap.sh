#!/bin/bash
set -euo pipefail

#################################################
# MongoDB Full Bootstrap
# Shopixy Infrastructure
#################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

#################################################
# Load Environment
#################################################

# FIX 16: Added existence check — missing .env previously caused a cryptic bash error.
if [ ! -f ".env" ]; then
    echo "ERROR: .env not found in $PROJECT_ROOT" >&2
    exit 1
fi

source .env

NAMESPACE="mongo-bootstrap-test"

echo ""
echo "=================================================="
echo " MongoDB Full Bootstrap"
echo "=================================================="
echo ""

#################################################
# Namespace
#################################################

echo "[1/10] Applying namespace..."

sudo kubectl apply -f bootstrap-test/namespace.yaml

#################################################
# Keyfile Secret
#################################################

echo "[2/10] Creating keyfile secret..."

# FIX 1-2: Added missing `\` line continuations.
sudo kubectl delete secret mongo-keyfile \
    -n "$NAMESPACE" \
    --ignore-not-found

sudo kubectl create secret generic mongo-keyfile \
    --from-file=mongo-keyfile=secrets/mongo-keyfile \
    -n "$NAMESPACE"

#################################################
# Headless Service
#################################################

echo "[3/10] Applying headless service..."

sudo kubectl apply -f bootstrap-test/mongo-headless-service.yaml

#################################################
# Bootstrap StatefulSet (NO AUTH)
#################################################

echo "[4/10] Deploying bootstrap StatefulSet..."

sudo kubectl apply -f bootstrap-test/mongo-statefulset.yaml

echo ""
echo "Waiting for pods..."
echo ""

# FIX 3: Added missing `\` line continuations.
sudo kubectl rollout status \
    statefulset/mongo \
    -n "$NAMESPACE" \
    --timeout=10m

#################################################
# Wait For Mongo To Accept Connections
#################################################

echo "[5/10] Waiting for MongoDB to accept connections..."

# FIX 15: Replaced hardcoded sleep 20 with a proper connection retry loop.
# rollout status confirms pods are Running, but mongod may not be ready to accept
# connections yet. This polls until mongo responds or times out.
for _i in {1..30}; do
    if sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
        mongo --quiet --eval "print('ok')" >/dev/null 2>&1; then
        echo "MongoDB is accepting connections"
        break
    fi
    sleep 3
done

#################################################
# Replica Set Init
#################################################

echo "[6/10] Initializing ReplicaSet..."

# FIX 4: Added missing `\` line continuations.
sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo --quiet --eval "
        try {
            rs.initiate({
                _id: '$MONGO_REPLICA_SET',
                members: [
                    { _id: 0, host: 'mongo-0.mongo-headless.$NAMESPACE.svc.cluster.local:27017' },
                    { _id: 1, host: 'mongo-1.mongo-headless.$NAMESPACE.svc.cluster.local:27017' },
                    { _id: 2, host: 'mongo-2.mongo-headless.$NAMESPACE.svc.cluster.local:27017' }
                ]
            })
        } catch(e) {
            print(e)
        }
    "

#################################################
# Wait Primary Election
#################################################

echo "[7/10] Waiting for PRIMARY election..."

# FIX 10: db.hello() does not exist in MongoDB 4.4 (introduced in 5.0).
#          Replaced with db.isMaster() and the correct 4.4 field 'ismaster' (lowercase).
# FIX 11: Loop previously fell through silently after 60 failures and continued the script.
#          Now explicitly exits with an error if no primary is elected in time.
# FIX 17: Added `|| true` so kubectl exec failures (pod not ready) don't kill the loop
#          under set -e — they're retried instead of aborting the script.
PRIMARY_ELECTED=false
for _i in {1..60}; do
    RESULT=$(sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
        mongo --quiet --eval "
            try {
                print(db.isMaster().ismaster)
            } catch(e) {
                print(false)
            }
        " 2>/dev/null | tail -n1 || true)

    if [[ "$RESULT" == "true" ]]; then
        echo "PRIMARY elected"
        PRIMARY_ELECTED=true
        break
    fi

    sleep 5
done

if [ "$PRIMARY_ELECTED" != "true" ]; then
    echo "ERROR: Timed out waiting for PRIMARY election (300s)" >&2
    exit 1
fi

#################################################
# Create Admin User
#################################################

echo "[8/10] Creating admin user..."

# FIX 6: Added missing `\` line continuations.
sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo admin --quiet --eval "
        try {
            db.createUser({
                user: '$MONGO_ADMIN_USER',
                pwd:  '$MONGO_ADMIN_PASSWORD',
                roles: [{ role: 'root', db: 'admin' }]
            })
        } catch(e) {
            print(e)
        }
    "

#################################################
# Create App User
#################################################

echo "[9/10] Creating application user..."

# FIX 7: Added missing `\` line continuations.
# FIX 14: Replaced global `db = db.getSiblingDB(...)` reassignment with a local variable.
sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "
            var appDb = db.getSiblingDB('$SHOPIXY_DB');
            try {
                appDb.createUser({
                    user: '$SHOPIXY_USER',
                    pwd:  '$SHOPIXY_PASSWORD',
                    roles: [{ role: 'readWrite', db: '$SHOPIXY_DB' }]
                });
            } catch(e) {
                print(e)
            }
        "

#################################################
# Switch To Production StatefulSet (WITH AUTH)
#################################################

echo "[10/10] Enabling authentication..."

sudo kubectl apply -f mongo-statefulset.yaml

# FIX 8: Added missing `\` line continuations.
sudo kubectl rollout status \
    statefulset/mongo \
    -n "$NAMESPACE" \
    --timeout=10m

#################################################
# Verification
#################################################

echo ""
echo "=================================================="
echo " Verification"
echo "=================================================="

# FIX 9: Added missing `\` line continuations.
sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "db.runCommand({ connectionStatus: 1 })"

echo ""
echo "ReplicaSet Status:"
echo ""

# FIX 9: Added missing `\` line continuations.
# FIX 18: .map() return value is not auto-printed in mongo --eval context.
#          Wrapped in printjson() so output is actually visible.
sudo kubectl exec -n "$NAMESPACE" mongo-0 -- \
    mongo admin \
        -u "$MONGO_ADMIN_USER" \
        -p "$MONGO_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --quiet \
        --eval "
            printjson(
                rs.status().members.map(function(m) {
                    return { name: m.name, state: m.stateStr, health: m.health }
                })
            )
        "

echo ""
echo "=================================================="
echo " BOOTSTRAP COMPLETED SUCCESSFULLY"
echo "=================================================="
echo ""
