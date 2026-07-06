#!/bin/bash
set -Eeuo pipefail

############################################
# Globals
############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"
HELM="sudo -E helm"

############################################
# Load Environment
############################################

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "ERROR: .env file not found."
    exit 1
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

############################################
# Banner
############################################

echo "=================================================="
echo "      Shopixy PostgreSQL Bootstrap v4"
echo "=================================================="
echo ""

############################################
# Generate YAML Files
############################################

echo "[1/16] Generating configuration files..."

chmod +x "$SCRIPT_DIR/generate-configs.sh"

bash "$SCRIPT_DIR/generate-configs.sh"

echo "[OK]"
echo ""

############################################
# Install CloudNativePG
############################################

echo "[2/16] Installing CloudNativePG Operator..."

$HELM repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true

$HELM repo update

$HELM upgrade \
    --install cnpg \
    cnpg/cloudnative-pg \
    -n cnpg-system \
    --create-namespace \
    --wait

echo "[OK]"
echo ""

############################################
# Wait Operator
############################################

echo "[3/16] Waiting for Operator..."

$KUBECTL rollout status \
deployment/cnpg-cloudnative-pg \
-n cnpg-system \
--timeout=300s

echo "[OK]"
echo ""

############################################
# Verify Plugin
############################################

echo "[4/16] Verifying Barman Plugin..."

PLUGIN_COUNT=$($KUBECTL get deployment \
-n cnpg-system \
plugin-barman-cloud \
--ignore-not-found \
--no-headers | wc -l)

if [[ "$PLUGIN_COUNT" -eq 0 ]]; then
    echo ""
    echo "ERROR:"
    echo "plugin-barman-cloud is not installed."
    echo ""
    exit 1
fi

echo "[OK]"
echo ""

############################################
# Namespace
############################################

echo "[5/16] Creating Namespace..."

$KUBECTL apply -f "$SCRIPT_DIR/namespace.yaml"

echo "[OK]"
echo ""

############################################
# Database Secret
############################################

echo "[6/16] Creating PostgreSQL Secret..."

$KUBECTL apply -f "$SCRIPT_DIR/secret.yaml"

echo "[OK]"
echo ""

############################################
# MinIO Secret
############################################

echo "[7/16] Creating MinIO Secret..."

cat > "$SCRIPT_DIR/minio-backup-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-backup-secret
  namespace: postgresql
type: Opaque
stringData:
  ACCESS_KEY_ID: "${MINIO_ACCESS_KEY}"
  ACCESS_SECRET_KEY: "${MINIO_SECRET_KEY}"
EOF

$KUBECTL apply -f "$SCRIPT_DIR/minio-backup-secret.yaml"

echo "[OK]"
echo ""

############################################
# Configure ObjectStore
#
# NOTE: This MUST happen before the Cluster is
# ever applied, because cluster.yaml references
# the barman-cloud plugin, which in turn depends
# on the shopixy-backup ObjectStore existing.
############################################

echo "[8/16] Creating ObjectStore..."

cat > "$SCRIPT_DIR/objectstore.yaml" <<EOF
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: shopixy-backup
  namespace: postgresql

spec:
  configuration:

    destinationPath: ${MINIO_DESTINATION_PATH}
    endpointURL: ${MINIO_ENDPOINT}

    s3Credentials:
      accessKeyId:
        name: minio-backup-secret
        key: ACCESS_KEY_ID

      secretAccessKey:
        name: minio-backup-secret
        key: ACCESS_SECRET_KEY

    wal:
      compression: zstd
      maxParallel: 4

    data:
      compression: gzip
      jobs: 2

  retentionPolicy: 30d
EOF

$KUBECTL apply -f "$SCRIPT_DIR/objectstore.yaml"

echo "[OK]"
echo ""

############################################
# Verify ObjectStore
############################################

echo "[9/16] Verifying ObjectStore..."

$KUBECTL get objectstore \
shopixy-backup \
-n postgresql >/dev/null

echo "[OK]"
echo ""

############################################
# Verify Generated Cluster
############################################

echo "[10/16] Validating Generated YAML..."

grep -q "^kind: Cluster" "$SCRIPT_DIR/cluster.yaml"

grep -q "^  plugins:" "$SCRIPT_DIR/cluster.yaml"

echo "[OK]"
echo ""

############################################
# Ready
############################################

echo "[11/16] Environment Ready"

echo ""
echo "------------------------------------------"
echo "CNPG Operator      : OK"
echo "Barman Plugin      : OK"
echo "Namespace          : OK"
echo "Secrets            : OK"
echo "ObjectStore        : OK"
echo "Generated YAML     : OK"
echo "------------------------------------------"

############################################
# PostgreSQL Cluster
############################################

echo "[12/16] Creating PostgreSQL Cluster..."

$KUBECTL apply -f "$SCRIPT_DIR/cluster.yaml"

echo "[OK]"
echo ""

############################################
# Wait Cluster Resource
############################################

echo "Waiting for Cluster resource..."

for i in $(seq 1 60); do

    if $KUBECTL get cluster shopixy-postgres \
        -n postgresql >/dev/null 2>&1
    then
        break
    fi

    sleep 2

done

############################################
# Wait Primary Pod
#
# kubectl wait only waits on a CONDITION of an
# already-existing object — it does not wait for
# the object itself to be created, and errors
# immediately with NotFound if it doesn't exist
# yet. The operator needs a few seconds after the
# Cluster appears before it creates the pod, so we
# poll for existence first.
############################################

echo "Waiting for Primary Pod to be created..."

POD_FOUND=false

for i in $(seq 1 150); do

    if $KUBECTL get pod shopixy-postgres-1 \
        -n postgresql >/dev/null 2>&1
    then
        POD_FOUND=true
        break
    fi

    sleep 2

done

if [ "$POD_FOUND" = false ]; then
    echo ""
    echo "ERROR:"
    echo "Primary Pod shopixy-postgres-1 was never created."
    echo ""
    $KUBECTL get pods -n postgresql
    exit 1
fi

echo "Waiting for Primary Pod to be Ready..."

$KUBECTL wait \
pod/shopixy-postgres-1 \
-n postgresql \
--for=condition=Ready \
--timeout=900s

############################################
# Wait Cluster Healthy
############################################

echo "Waiting for Cluster Ready..."

$KUBECTL wait \
cluster/shopixy-postgres \
-n postgresql \
--for=condition=Ready \
--timeout=900s

############################################
# Wait Desired Replicas
############################################

echo "Waiting for all PostgreSQL replicas..."

EXPECTED="${POSTGRES_INSTANCES}"

for i in $(seq 1 180)
do

READY=$($KUBECTL get cluster shopixy-postgres \
-n postgresql \
-o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)

if [[ "$READY" == "$EXPECTED" ]]; then
    break
fi

echo "  Ready: ${READY}/${EXPECTED}"

sleep 5

done

READY=$($KUBECTL get cluster shopixy-postgres \
-n postgresql \
-o jsonpath='{.status.readyInstances}')

if [[ "$READY" != "$EXPECTED" ]]; then

    echo ""
    echo "ERROR:"
    echo "Cluster did not reach ${EXPECTED} Ready instances."
    echo ""

    $KUBECTL get pods -n postgresql

    exit 1

fi

echo "[OK]"
echo ""

############################################
# Verify Cluster Health
############################################

echo "Verifying Cluster Health..."

STATUS=$($KUBECTL get cluster shopixy-postgres \
-n postgresql \
-o jsonpath='{.status.phase}')

if [[ "$STATUS" != "Cluster in healthy state" ]]; then

    echo ""
    echo "ERROR:"
    echo "Cluster Phase:"
    echo "$STATUS"
    echo ""

    exit 1

fi

echo "[OK]"
echo ""

############################################
# Verify Primary
############################################

PRIMARY=$($KUBECTL get cluster shopixy-postgres \
-n postgresql \
-o jsonpath='{.status.currentPrimary}')

if [[ -z "$PRIMARY" ]]; then

    echo "ERROR: Primary node not found."

    exit 1

fi

echo "Primary Node : $PRIMARY"

echo ""

############################################
# Verify Services
############################################

echo "Checking PostgreSQL Services..."

for svc in \
shopixy-postgres-rw \
shopixy-postgres-r \
shopixy-postgres-ro
do

$KUBECTL get svc \
"$svc" \
-n postgresql >/dev/null

done

echo "[OK]"

echo ""

############################################
# PgBouncer
############################################

echo "[13/16] Creating PgBouncer..."

$KUBECTL apply \
-f "$SCRIPT_DIR/pgbouncer.yaml"

############################################
# Wait Pooler
############################################

echo "Waiting for PgBouncer Pods..."

COUNT=0

for i in $(seq 1 120)
do

COUNT=$($KUBECTL get pods \
-n postgresql \
-l cnpg.io/poolerName=shopixy-pgbouncer \
--no-headers 2>/dev/null | wc -l)

if [[ "$COUNT" -gt 0 ]]; then
    break
fi

sleep 2

done

if [[ "$COUNT" -eq 0 ]]; then

    echo "ERROR:"
    echo "PgBouncer Pods were not created."

    exit 1

fi

############################################
# Wait Ready
############################################

$KUBECTL wait pod \
-l cnpg.io/poolerName=shopixy-pgbouncer \
-n postgresql \
--for=condition=Ready \
--timeout=300s

############################################
# Verify Pooler
#
# NOTE: The Pooler CRD's .status does not expose
# a "readyPods" field, so reading it via jsonpath
# always returns empty. Verify readiness instead
# by counting Ready pods under the pooler label,
# which kubectl wait above already confirmed.
############################################

POOLER_READY=$($KUBECTL get pods \
-n postgresql \
-l cnpg.io/poolerName=shopixy-pgbouncer \
--no-headers 2>/dev/null | grep -c Running || true)

if [[ -z "$POOLER_READY" ]] || [[ "$POOLER_READY" -eq 0 ]]; then

    echo "ERROR:"
    echo "Unable to verify PgBouncer."

    exit 1

fi

echo ""

echo "[OK]"

echo ""

############################################
# Summary
############################################

echo "------------------------------------------"
echo "Cluster           : Healthy"
echo "Instances         : ${READY}/${EXPECTED}"
echo "Primary           : ${PRIMARY}"
echo "RW Service        : OK"
echo "RO Service        : OK"
echo "Pooler            : ${POOLER_READY} Ready"
echo "------------------------------------------"

############################################
# Scheduled Backup
############################################

echo "[14/16] Creating Scheduled Backup..."

cat > "$SCRIPT_DIR/scheduled-backup.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup

metadata:
  name: shopixy-postgres-scheduled
  namespace: postgresql

spec:
  schedule: "0 0 2 * * *"

  backupOwnerReference: self

  cluster:
    name: shopixy-postgres

  method: plugin

  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io

  immediate: false
EOF

$KUBECTL apply -f "$SCRIPT_DIR/scheduled-backup.yaml"

echo "[OK]"
echo ""

############################################
# First Backup
############################################

echo "[15/16] Creating First Backup..."

cat > "$SCRIPT_DIR/first-backup.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup

metadata:
  name: first-real-backup
  namespace: postgresql

spec:
  cluster:
    name: shopixy-postgres

  method: plugin

  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

$KUBECTL apply -f "$SCRIPT_DIR/first-backup.yaml"

echo ""

############################################
# Wait Backup
############################################

echo "Waiting For Backup Completion..."

BACKUP_DONE=false

for i in $(seq 1 180); do

    PHASE=$($KUBECTL get backup first-real-backup \
      -n postgresql \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)

    case "$PHASE" in
        completed)
            echo "Backup Completed Successfully"
            BACKUP_DONE=true
            break
            ;;

        failed)
            echo ""
            echo "Backup Failed"
            $KUBECTL describe backup first-real-backup -n postgresql
            exit 1
            ;;
    esac

    sleep 10

done

if [ "$BACKUP_DONE" = false ]; then
    echo "Backup Timeout"
    exit 1
fi

echo "[OK]"
echo ""

############################################
# Verify ObjectStore
############################################

echo "Checking ObjectStore..."

$KUBECTL get objectstore \
shopixy-backup \
-n postgresql

echo ""

############################################
# WAL Validation
############################################

echo "[16/16] Validating WAL Archiving..."

PRIMARY=$($KUBECTL get cluster shopixy-postgres \
  -n postgresql \
  -o jsonpath='{.status.currentPrimary}')

if [ -z "$PRIMARY" ]; then
    echo "ERROR: Unable to determine PostgreSQL primary."
    exit 1
fi

echo "Primary Node: $PRIMARY"
echo ""

############################################
# Generate WAL
#
# NOTE: This cluster uses plugin-based WAL
# archiving (barman-cloud.cloudnative-pg.io via
# spec.plugins, method: plugin). Under this
# architecture the instance manager calls the
# plugin's ArchiveWAL gRPC method directly and
# never invokes PostgreSQL's classic
# archive_command — so pg_stat_archiver.archived_count
# does NOT increment even when archiving is working
# correctly. We validate via the Cluster's
# ContinuousArchiving status condition instead,
# which the operator maintains specifically for
# plugin-based archiving.
############################################

echo "Generating WAL..."

$KUBECTL exec \
    -n postgresql \
    "$PRIMARY" \
    -- psql \
    -U postgres \
    -d shopixy <<'SQL'

CREATE TABLE IF NOT EXISTS bootstrap_wal_test
(
    id bigserial PRIMARY KEY,
    created_at timestamp default now()
);

INSERT INTO bootstrap_wal_test DEFAULT VALUES;

CHECKPOINT;

SELECT pg_switch_wal();

SQL

echo ""

############################################
# Wait For ContinuousArchiving Condition
############################################

echo "Waiting For WAL Archive..."

WAL_OK=false

for i in $(seq 1 30); do

    CONDITION=$($KUBECTL get cluster shopixy-postgres \
        -n postgresql \
        -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' \
        2>/dev/null || true)

    if [ "$CONDITION" = "True" ]; then
        WAL_OK=true
        break
    fi

    sleep 5

done

############################################
# Validate WAL
############################################

if [ "$WAL_OK" = false ]; then

    echo ""
    echo "ERROR: WAL Archiving Validation Failed."
    echo "ContinuousArchiving condition never reached True."
    echo ""

    $KUBECTL get cluster shopixy-postgres \
        -n postgresql \
        -o jsonpath='{.status.conditions}'

    echo ""

    exit 1

fi

echo "WAL Archiving Verified (ContinuousArchiving condition = True)."
echo ""

############################################
# Verify Plugin
############################################

echo "Checking Plugin Status..."

$KUBECTL get objectstore \
    shopixy-backup \
    -n postgresql

echo ""

############################################
# Verify Backup Objects
############################################

echo "Backup Status..."

$KUBECTL get backup \
    -n postgresql

echo ""

############################################
# Verify Scheduled Backup
############################################

echo "Scheduled Backup Status..."

$KUBECTL get scheduledbackup \
    -n postgresql

echo ""

############################################
# Verify Cluster
############################################

echo "Cluster Status..."

$KUBECTL get cluster \
    -n postgresql

echo ""

############################################
# Verify Pods
############################################

echo "PostgreSQL Pods..."

$KUBECTL get pods \
    -n postgresql \
    -o wide

echo ""

############################################
# Prometheus Integration
############################################

echo "Configuring Prometheus..."

$KUBECTL label podmonitor \
    shopixy-postgres \
    -n postgresql \
    release=prometheus \
    --overwrite >/dev/null 2>&1 || true

echo ""

############################################
# Services
############################################

echo "PostgreSQL Services..."

$KUBECTL get svc \
    -n postgresql

echo ""

############################################
# Pooler
############################################

echo "PgBouncer..."

$KUBECTL get pooler \
    -n postgresql

echo ""

############################################
# PVC
############################################

echo "Persistent Volumes..."

$KUBECTL get pvc \
    -n postgresql

echo ""

############################################
# ObjectStore
############################################

echo "ObjectStore..."

$KUBECTL get objectstore \
    -n postgresql

echo ""

############################################
# Backups
############################################

echo "Backups..."

$KUBECTL get backup \
    -n postgresql

echo ""

############################################
# Scheduled Backups
############################################

echo "Scheduled Backups..."

$KUBECTL get scheduledbackup \
    -n postgresql

echo ""

############################################
# Cluster
############################################

echo "Cluster..."

$KUBECTL get cluster \
    -n postgresql

echo ""

############################################
# Pods
############################################

echo "Pods..."

$KUBECTL get pods \
    -n postgresql \
    -o wide

echo ""

############################################
# Validate Ready Instances
############################################

READY=$($KUBECTL get cluster shopixy-postgres \
    -n postgresql \
    -o jsonpath='{.status.readyInstances}')

INSTANCES=$($KUBECTL get cluster shopixy-postgres \
    -n postgresql \
    -o jsonpath='{.spec.instances}')

if [ "$READY" != "$INSTANCES" ]; then
    echo "ERROR: Cluster is not fully healthy."
    exit 1
fi

############################################
# Validate Primary
############################################

PRIMARY=$($KUBECTL get cluster shopixy-postgres \
    -n postgresql \
    -o jsonpath='{.status.currentPrimary}')

if [ -z "$PRIMARY" ]; then
    echo "ERROR: No Primary detected."
    exit 1
fi

############################################
# Validate PgBouncer
############################################

PGBOUNCER_READY=$($KUBECTL get pods \
    -n postgresql \
    -l cnpg.io/poolerName=shopixy-pgbouncer \
    --no-headers 2>/dev/null | grep -c Running || true)

if [ -z "$PGBOUNCER_READY" ] || [ "$PGBOUNCER_READY" -eq 0 ]; then
    echo "ERROR: PgBouncer is not running."
    exit 1
fi

############################################
# Validate ObjectStore
############################################

OBJECTSTORE=$($KUBECTL get objectstore \
    shopixy-backup \
    -n postgresql \
    --ignore-not-found \
    -o name)

if [ -z "$OBJECTSTORE" ]; then
    echo "ERROR: ObjectStore not found."
    exit 1
fi

############################################
# Validate First Backup
############################################

BACKUP_PHASE=$($KUBECTL get backup first-real-backup \
    -n postgresql \
    -o jsonpath='{.status.phase}')

if [ "$BACKUP_PHASE" != "completed" ]; then
    echo "ERROR: Initial Backup failed."
    exit 1
fi

############################################
# Bootstrap Summary
############################################

echo ""
echo "==============================================="
echo " Shopixy PostgreSQL Bootstrap v4 Completed"
echo "==============================================="
echo ""

echo "Cluster        : Healthy"
echo "Primary        : $PRIMARY"
echo "Instances      : $READY/$INSTANCES"
echo "PgBouncer      : Running"
echo "ObjectStore    : Ready"
echo "Initial Backup : Completed"
echo "WAL Archive    : Verified"
echo ""

echo "Production Status : READY"
echo ""
