#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
source "$SCRIPT_DIR/.env"
set +a

echo "Generating secret.yaml..."

sed \
-e "s/__POSTGRES_USER__/$POSTGRES_USER/g" \
-e "s/__POSTGRES_PASSWORD__/$POSTGRES_PASSWORD/g" \
"$SCRIPT_DIR/secret-template.yaml" \
> "$SCRIPT_DIR/secret.yaml"

echo "Generating cluster.yaml..."

sed \
-e "s/__POSTGRES_CLUSTER_NAME__/$POSTGRES_CLUSTER_NAME/g" \
-e "s/__POSTGRES_DB__/$POSTGRES_DB/g" \
-e "s/__POSTGRES_USER__/$POSTGRES_USER/g" \
-e "s/__POSTGRES_INSTANCES__/$POSTGRES_INSTANCES/g" \
-e "s/__POSTGRES_STORAGE__/$POSTGRES_STORAGE/g" \
-e "s/__POSTGRES_CPU_REQUEST__/$POSTGRES_CPU_REQUEST/g" \
-e "s/__POSTGRES_MEMORY_REQUEST__/$POSTGRES_MEMORY_REQUEST/g" \
-e "s/__POSTGRES_CPU_LIMIT__/$POSTGRES_CPU_LIMIT/g" \
-e "s/__POSTGRES_MEMORY_LIMIT__/$POSTGRES_MEMORY_LIMIT/g" \
"$SCRIPT_DIR/cluster-template.yaml" \
> "$SCRIPT_DIR/cluster.yaml"

echo "Generating pgbouncer.yaml..."

sed \
-e "s/__POSTGRES_CLUSTER_NAME__/$POSTGRES_CLUSTER_NAME/g" \
"$SCRIPT_DIR/pgbouncer-template.yaml" \
> "$SCRIPT_DIR/pgbouncer.yaml"

echo "All configs generated successfully."
