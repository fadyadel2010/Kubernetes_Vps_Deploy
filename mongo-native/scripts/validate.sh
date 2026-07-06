#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

if [ ! -f ".env" ]; then
    echo "ERROR: .env not found in $PROJECT_ROOT" >&2
    exit 1
fi

source .env

NAMESPACE="$MONGO_NAMESPACE"



#################################################
# Verification
#################################################

echo ""
echo "=================================================="
echo " Verification"
echo "=================================================="

for BIN in kubectl mongo
do
    if ! command -v "$BIN" >/dev/null 2>&1
    then
        echo "ERROR: Missing dependency: $BIN"
        exit 1
    fi
done

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
