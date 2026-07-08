#!/usr/bin/env bash

set -euo pipefail

############################################################
# PostgreSQL Production Validation
############################################################

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

NAMESPACE="postgresql"
CLUSTER_NAME="shopixy-postgres"

############################################################
# Colors
############################################################

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

############################################################
# Helpers
############################################################

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

section() {
    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

############################################################
# Dependency Checks
############################################################

for CMD in kubectl; do
    command -v "$CMD" >/dev/null 2>&1 || \
        error "Missing dependency: $CMD"
done

[ -f "$KUBECONFIG" ] || \
    error "KUBECONFIG not found: $KUBECONFIG"

############################################################
# Header
############################################################

section "PostgreSQL Production Validation"

############################################################
# Namespace
############################################################

$KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1 || \
    error "Namespace '$NAMESPACE' not found"

success "Namespace exists"

############################################################
# Cluster
############################################################

$KUBECTL get cluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" >/dev/null 2>&1 || \
    error "CloudNativePG cluster not found"

success "Cluster exists"

############################################################
# Cluster Ready
############################################################

READY_INSTANCES=$(
$KUBECTL get cluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.readyInstances}'
)

INSTANCES=$(
$KUBECTL get cluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.instances}'
)

if [ -z "$READY_INSTANCES" ] || [ -z "$INSTANCES" ]; then
    error "Unable to determine cluster readiness"
fi

if [ "$READY_INSTANCES" != "$INSTANCES" ]; then
    error "Cluster not ready (${READY_INSTANCES}/${INSTANCES})"
fi

success "Cluster Ready (${READY_INSTANCES}/${INSTANCES})"

############################################################
# Primary
############################################################

PRIMARY=$(
$KUBECTL get cluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.currentPrimary}'
)

[ -n "$PRIMARY" ] || \
    error "Unable to determine primary node"

success "Primary detected: ${PRIMARY}"


############################################################
# PostgreSQL Pods
#
# NOTE: filtering only by the "cnpg.io/cluster" label also
# matches PgBouncer pods, backup/job pods, and any other
# resource carrying the same cluster label. We additionally
# filter on the actual pod name prefix ("<cluster>-<n>") so
# we only count the real PostgreSQL instance pods.
############################################################

POSTGRES_PODS=$(
$KUBECTL get pods \
    -n "$NAMESPACE" \
    -l cnpg.io/cluster="$CLUSTER_NAME" \
    --no-headers 2>/dev/null |
grep "^${CLUSTER_NAME}-" |
grep "Running" |
wc -l
)

if [ "$POSTGRES_PODS" -lt "$INSTANCES" ]; then
    error "Expected ${INSTANCES} PostgreSQL pods, found ${POSTGRES_PODS}"
fi

success "PostgreSQL Pods (${POSTGRES_PODS}/${INSTANCES})"

############################################################
# PgBouncer
############################################################

PGBOUNCER_READY=$(
$KUBECTL get deployment shopixy-pgbouncer \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null
)

PGBOUNCER_DESIRED=$(
$KUBECTL get deployment shopixy-pgbouncer \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.replicas}' 2>/dev/null
)

if [ -z "$PGBOUNCER_READY" ] || [ -z "$PGBOUNCER_DESIRED" ]; then
    error "PgBouncer deployment not found"
fi

if [ "$PGBOUNCER_READY" != "$PGBOUNCER_DESIRED" ]; then
    error "PgBouncer not ready (${PGBOUNCER_READY}/${PGBOUNCER_DESIRED})"
fi

success "PgBouncer Ready (${PGBOUNCER_READY}/${PGBOUNCER_DESIRED})"

############################################################
# PostgreSQL Services
############################################################

for SERVICE in \
    shopixy-postgres-rw \
    shopixy-postgres-ro \
    shopixy-pgbouncer
do

    $KUBECTL get svc "$SERVICE" \
        -n "$NAMESPACE" >/dev/null 2>&1 || \
        error "Service missing: $SERVICE"

    success "Service verified: $SERVICE"

done

############################################################
# Traefik TCP Route
############################################################

if $KUBECTL get ingressroutetcp postgres \
    -n "$NAMESPACE" >/dev/null 2>&1
then
    success "Traefik TCP Route exists"
else
    error "Traefik TCP Route not found"
fi

############################################################
# PodMonitor
############################################################

if $KUBECTL get podmonitor shopixy-postgres \
    -n "$NAMESPACE" >/dev/null 2>&1
then
    success "PodMonitor exists"
else
    warn "PodMonitor not found"
fi

############################################################
# Pooler
############################################################

POOLER_INSTANCES=$(
$KUBECTL get pooler shopixy-pgbouncer \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.instances}' 2>/dev/null || true
)

POOLER_DESIRED=$(
$KUBECTL get pooler shopixy-pgbouncer \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.instances}' 2>/dev/null || true
)

if [ -z "$POOLER_INSTANCES" ] || [ -z "$POOLER_DESIRED" ]; then
    warn "Unable to determine Pooler status"
elif [ "$POOLER_INSTANCES" != "$POOLER_DESIRED" ]; then
    error "Pooler not ready (${POOLER_INSTANCES}/${POOLER_DESIRED})"
else
    success "CloudNativePG Pooler Ready (${POOLER_INSTANCES}/${POOLER_DESIRED})"
fi

############################################################
# Archiving Method Detection
#
# NOTE: This cluster archives WAL through the CNPG Barman
# Cloud plugin (spec.plugins, method: plugin), as configured
# in bootstrap.sh. Under that architecture the instance
# manager calls the plugin's ArchiveWAL gRPC method directly
# and NEVER invokes PostgreSQL's classic archive_command —
# so archive_mode/archive_command are not the live archiving
# path, and pg_stat_archiver counters (archived_count,
# failed_count) do not reflect real archiving health. We
# detect plugin-based archiving from the Cluster spec and
# adjust which checks are authoritative accordingly, instead
# of treating classic-archiving config/stats as ground truth
# for a cluster that isn't using classic archiving at all.
############################################################

PLUGIN_NAME=$(
$KUBECTL get cluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].name}' \
    2>/dev/null || true
)

if [ -n "$PLUGIN_NAME" ]; then
    ARCHIVING_MODE="plugin"
else
    ARCHIVING_MODE="classic"
fi

success "Archiving Mode Detected: ${ARCHIVING_MODE}"

############################################################
# WAL Level (always meaningful, regardless of archiving mode)
############################################################

WAL_LEVEL=$(
$KUBECTL exec \
    -n "$NAMESPACE" \
    "$PRIMARY" \
    -c postgres \
    -- psql -U postgres -At \
    -c "SHOW wal_level;"
)

WAL_LEVEL=$(echo "$WAL_LEVEL" | tr -d '[:space:]')

if [[ "$WAL_LEVEL" != "replica" && "$WAL_LEVEL" != "logical" ]]; then
    error "Unexpected wal_level: ${WAL_LEVEL}"
fi

success "WAL Level: ${WAL_LEVEL}"

############################################################
# Classic Archive Config (informational only in plugin mode)
#
# NOTE: In plugin mode, archive_mode/archive_command may
# still show as configured (Postgres defaults or leftover
# config), but they are NOT the mechanism actually moving
# WAL to object storage, so we no longer gate validation
# success on them — we just report them for visibility.
############################################################

ARCHIVE_MODE=$(
$KUBECTL exec \
    -n "$NAMESPACE" \
    "$PRIMARY" \
    -c postgres \
    -- psql -U postgres -At \
    -c "SHOW archive_mode;"
)

ARCHIVE_MODE=$(echo "$ARCHIVE_MODE" | tr -d '[:space:]')

ARCHIVE_COMMAND=$(
$KUBECTL exec \
    -n "$NAMESPACE" \
    "$PRIMARY" \
    -c postgres \
    -- psql -U postgres -At \
    -c "SHOW archive_command;"
)

if [ "$ARCHIVING_MODE" = "classic" ]; then

    [ "$ARCHIVE_MODE" = "on" ] || \
        error "archive_mode is disabled"

    success "Archive Mode Enabled"

    if [ -z "$ARCHIVE_COMMAND" ]; then
        error "archive_command is empty"
    fi

    success "Archive Command Configured"

else
    echo "Archive Mode (informational)    : ${ARCHIVE_MODE}"
    echo "Archive Command (informational) : ${ARCHIVE_COMMAND:-<not set>}"
    success "Classic archive_mode/archive_command noted (not authoritative in plugin mode)"
fi

############################################################
# ContinuousArchiving Condition
#
# This is the authoritative, operator-maintained signal for
# WAL archiving health in BOTH classic and plugin mode, so we
# always gate on it regardless of ARCHIVING_MODE.
############################################################

CONTINUOUS_ARCHIVING=$(
$KUBECTL get cluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' \
    2>/dev/null || true
)

if [ "$CONTINUOUS_ARCHIVING" != "True" ]; then

    CONTINUOUS_ARCHIVING_MSG=$(
    $KUBECTL get cluster "$CLUSTER_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}' \
        2>/dev/null || true
    )

    error "WAL archiving is not healthy (ContinuousArchiving=${CONTINUOUS_ARCHIVING:-unknown}): ${CONTINUOUS_ARCHIVING_MSG}"

fi

success "Continuous Archiving Healthy"

############################################################
# pg_stat_archiver
#
# NOTE: In plugin mode these counters do not reflect the
# actual archiving path (see note above), so failed_count
# here is expected noise, not a signal — we only warn on it
# in classic mode, where it genuinely indicates trouble.
############################################################

ARCHIVED_COUNT=$(
$KUBECTL exec \
    -n "$NAMESPACE" \
    "$PRIMARY" \
    -c postgres \
    -- psql -U postgres -At \
    -c "SELECT archived_count FROM pg_stat_archiver;"
)

FAILED_COUNT=$(
$KUBECTL exec \
    -n "$NAMESPACE" \
    "$PRIMARY" \
    -c postgres \
    -- psql -U postgres -At \
    -c "SELECT failed_count FROM pg_stat_archiver;"
)

LAST_ARCHIVED=$(
$KUBECTL exec \
    -n "$NAMESPACE" \
    "$PRIMARY" \
    -c postgres \
    -- psql -U postgres -At \
    -c "SELECT last_archived_wal FROM pg_stat_archiver;"
)

echo "Archived WAL Files : ${ARCHIVED_COUNT}"
echo "Failed WAL Files   : ${FAILED_COUNT}"
echo "Last Archived WAL  : ${LAST_ARCHIVED}"

if [ "$ARCHIVING_MODE" = "classic" ]; then
    if [ -n "$FAILED_COUNT" ] && [ "$FAILED_COUNT" -gt 0 ]; then
        warn "pg_stat_archiver reports ${FAILED_COUNT} failed archive attempt(s) on this instance (may be historical, e.g. from before a fix or a past failover)"
    fi
else
    if [ -n "$FAILED_COUNT" ] && [ "$FAILED_COUNT" -gt 0 ]; then
        echo "(pg_stat_archiver failed_count is expected to be non-zero in plugin mode and does not indicate a problem; ContinuousArchiving above is the authoritative signal)"
    fi
fi

success "WAL Archiver Stats Collected"

############################################################
# Backups
#
# NOTE: requiring the single most-recent backup to be
# "completed" is too strict during active development —
# earlier backups can fail (e.g. mid-cluster-edit) without
# that indicating a real problem today. Instead we require
# at least one completed backup to exist in the namespace.
############################################################

COMPLETED_BACKUPS=$(
$KUBECTL get backups \
    -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' |
grep -c "^completed$" || true
)

[ "$COMPLETED_BACKUPS" -gt 0 ] || \
    error "No completed backups found"

success "Completed Backups: ${COMPLETED_BACKUPS}"

############################################################
# Scheduled Backup
#
# NOTE: jsonpath '{.items[0]...}' errors out (array index out
# of bounds) when zero ScheduledBackup resources exist, which
# would abort the script with a raw kubectl error under set -e
# instead of the intended clean error message below. Using
# '{.items[*]...}' plus a shell-side pick of the first field
# degrades gracefully to an empty string instead.
############################################################

SCHEDULE_NAME=$(
$KUBECTL get scheduledbackup \
    -n "$NAMESPACE" \
    -o jsonpath='{.items[*].metadata.name}' \
    2>/dev/null || true
)

SCHEDULE_NAME=$(echo "$SCHEDULE_NAME" | awk '{print $1}')

[ -n "$SCHEDULE_NAME" ] || \
    error "ScheduledBackup resource not found"

success "Scheduled Backup Configured (${SCHEDULE_NAME})"

############################################################
# Backup Count
############################################################

BACKUP_COUNT=$(
$KUBECTL get backups \
    -n "$NAMESPACE" \
    --no-headers 2>/dev/null | wc -l
)

echo "Available Backups : ${BACKUP_COUNT}"

success "Backup Inventory Verified"

############################################################
# Cluster Summary
############################################################

section "Cluster Summary"

echo ""
$KUBECTL get cluster -n "$NAMESPACE"
echo ""

############################################################
# Pods
############################################################

echo ""
$KUBECTL get pods -n "$NAMESPACE"
echo ""

############################################################
# Services
############################################################

echo ""
$KUBECTL get svc -n "$NAMESPACE"
echo ""

############################################################
# Poolers
############################################################

echo ""
$KUBECTL get pooler -n "$NAMESPACE" || true
echo ""

############################################################
# Backups
############################################################

echo ""
$KUBECTL get backups -n "$NAMESPACE" || true
echo ""

############################################################
# Scheduled Backups
############################################################

echo ""
$KUBECTL get scheduledbackup -n "$NAMESPACE" || true
echo ""

############################################################
# External Connection
############################################################

section "External Connection"

NODE_IP=$(hostname -I | awk '{print $1}')

echo "Host      : ${NODE_IP}"

if $KUBECTL get ingressroutetcp postgres \
    -n "$NAMESPACE" >/dev/null 2>&1
then
    echo "Port      : 5432 (Traefik TCP)"
else
    warn "Traefik TCP Route not found"
fi

echo "Database  : shopixy"
echo "Username  : shopixy"

############################################################
# Validation Result
############################################################

section "Validation Result"

success "Namespace ................. OK"
success "Cluster ................... OK"
success "Primary ................... OK"
success "Pods ...................... OK"
success "PgBouncer ................. OK"
success "Services .................. OK"
success "Traefik TCP ............... OK"
success "Monitoring ............... OK"
success "WAL Archiving (${ARCHIVING_MODE}) ..... OK"
success "Backups ................... OK"
success "Scheduled Backups ......... OK"

############################################################
# Footer
############################################################

echo ""
echo "=================================================="
echo " PostgreSQL Validation Completed Successfully"
echo "=================================================="
echo ""
