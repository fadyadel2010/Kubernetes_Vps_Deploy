#!/usr/bin/env bash
set -Eeuo pipefail

############################################################
# Configuration
############################################################

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KUBECTL="sudo -E kubectl --kubeconfig=${KUBECONFIG}"

NAMESPACE="rabbitmq"
RABBITMQ_CLUSTER_NAME="rabbitmq"       # name of the RabbitmqCluster CR
STATEFULSET_NAME="rabbitmq-server"     # actual pod/statefulset prefix

############################################################
# Colors
############################################################

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

############################################################
# Helpers
############################################################

section() {
    echo ""
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

############################################################
# Dependency Checks
############################################################

for BIN in kubectl jq curl
do
    command -v "$BIN" >/dev/null 2>&1 || error "Missing dependency: $BIN"
done

section "RabbitMQ Production Validation"

############################################################
# Namespace
############################################################

$KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1 || \
    error "Namespace '$NAMESPACE' not found"
success "Namespace exists"

############################################################
# RabbitMQ Cluster
############################################################

$KUBECTL get rabbitmqcluster "$RABBITMQ_CLUSTER_NAME" \
    -n "$NAMESPACE" >/dev/null 2>&1 || \
    error "RabbitMQCluster '$RABBITMQ_CLUSTER_NAME' not found"
success "RabbitMQ Cluster exists"

############################################################
# Cluster Ready (condition-based, matches bootstrap.sh)
############################################################

ALL_REPLICAS_READY=$(
$KUBECTL get rabbitmqcluster "$RABBITMQ_CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="AllReplicasReady")].status}' 2>/dev/null || true
)

RECONCILE_SUCCESS=$(
$KUBECTL get rabbitmqcluster "$RABBITMQ_CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="ReconcileSuccess")].status}' 2>/dev/null || true
)

DESIRED_REPLICAS=$(
$KUBECTL get rabbitmqcluster "$RABBITMQ_CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || true
)

[ "$ALL_REPLICAS_READY" = "True" ] || \
    error "RabbitMQ Cluster not ready (AllReplicasReady=${ALL_REPLICAS_READY:-Unknown})"
success "Cluster Ready (AllReplicasReady=True, desired replicas=${DESIRED_REPLICAS})"

[ "$RECONCILE_SUCCESS" = "True" ] || \
    warn "ReconcileSuccess condition is not True (${RECONCILE_SUCCESS:-Unknown})"
[ "$RECONCILE_SUCCESS" = "True" ] && success "ReconcileSuccess"

############################################################
# RabbitMQ Pods
############################################################

RUNNING_PODS=$(
$KUBECTL get pods \
    -n "$NAMESPACE" \
    --no-headers 2>/dev/null |
grep "^${STATEFULSET_NAME}-" |
grep "Running" |
wc -l
)

[ "$RUNNING_PODS" -eq "$DESIRED_REPLICAS" ] || \
    error "RabbitMQ Pods (${RUNNING_PODS}/${DESIRED_REPLICAS})"
success "RabbitMQ Pods (${RUNNING_PODS}/${DESIRED_REPLICAS})"

############################################################
# StatefulSet
############################################################

$KUBECTL get statefulset "$STATEFULSET_NAME" \
    -n "$NAMESPACE" >/dev/null 2>&1 || \
    error "StatefulSet not found"
success "StatefulSet exists"

############################################################
# TLS Secrets
############################################################

for SECRET in rabbitmq-ca-secret rabbitmq-server-tls
do
    if $KUBECTL get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1
    then
        success "TLS secret '$SECRET' exists"
    else
        error "TLS secret '$SECRET' not found"
    fi
done

############################################################
# Operators
############################################################

if $KUBECTL get pods -n rabbitmq-system --no-headers 2>/dev/null | \
    grep rabbitmq-cluster-operator | grep -q Running
then
    success "RabbitMQ Cluster Operator Running"
else
    warn "RabbitMQ Cluster Operator not found"
fi

if $KUBECTL get pods -n rabbitmq-system --no-headers 2>/dev/null | \
    grep messaging-topology-operator | grep -q Running
then
    success "Messaging Topology Operator Running"
else
    warn "Messaging Topology Operator not found"
fi

############################################################
# Topology Resources
############################################################

section "Topology Resources"

check_topology_resource() {
    local KIND="$1"
    local NAME="$2"
    if $KUBECTL get "$KIND" "$NAME" -n "$NAMESPACE" >/dev/null 2>&1
    then
        local READY
        READY=$($KUBECTL get "$KIND" "$NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [ "$READY" = "True" ]
        then
            success "${KIND}/${NAME} Ready"
        else
            warn "${KIND}/${NAME} exists but Ready=${READY:-Unknown}"
        fi
    else
        error "${KIND}/${NAME} not found"
    fi
}

check_topology_resource vhost shopixy
check_topology_resource user shopixy-app
check_topology_resource permission shopixy-app
check_topology_resource exchange shopixy-events
check_topology_resource queue orders
check_topology_resource queue products
check_topology_resource queue notifications

check_topology_resource binding.rabbitmq.com orders-binding
check_topology_resource binding.rabbitmq.com products-binding
check_topology_resource binding.rabbitmq.com notifications-binding

# Bindings don't support the Ready condition check reliably via list verb
# in this operator version — just confirm they exist.
for BINDING in orders-binding products-binding notifications-binding
do
    if $KUBECTL get binding.rabbitmq.com "$BINDING" -n "$NAMESPACE" >/dev/null 2>&1
    then
        READY=$(
            $KUBECTL get binding.rabbitmq.com "$BINDING" \
                -n "$NAMESPACE" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
                2>/dev/null || true
        )

        if [ "$READY" = "True" ]; then
            success "binding/${BINDING} Ready"
        else
            warn "binding/${BINDING} exists but Ready=${READY:-Unknown}"
        fi
    else
        error "binding/${BINDING} not found"
    fi
done

############################################################
# Monitor Check
############################################################

sudo kubectl get endpoints rabbitmq-metrics -n rabbitmq

############################################################
# Cluster Status (functional check)
############################################################

section "Cluster Status"

$KUBECTL exec -n "$NAMESPACE" "${STATEFULSET_NAME}-0" -- rabbitmqctl cluster_status \
    >/dev/null 2>&1 && success "rabbitmqctl cluster_status responded" \
    || error "rabbitmqctl cluster_status failed"

section "Validation Complete"
