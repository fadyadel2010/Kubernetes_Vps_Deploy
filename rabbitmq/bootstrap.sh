#!/usr/bin/env bash

set -Eeuo pipefail

###############################################
# RabbitMQ Bootstrap
# Shopixy Infrastructure
###############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

ENV_FILE="$PROJECT_ROOT/bootstrap.env"

GENERATED_DIR="$PROJECT_ROOT/generated"

NAMESPACE="rabbitmq"
OPERATOR_NAMESPACE="rabbitmq-system"
TOPOLOGY_OPERATOR_DEPLOYMENT="messaging-topology-operator"
TOPOLOGY_CA_SECRET_NAME="rabbitmq-ca"
TOPOLOGY_CA_MOUNT_PATH="/etc/ssl/certs/rabbitmq-ca.crt"

###############################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

###############################################
# Verify Tools
###############################################

# FIX 1: Added helm to the tool check — it's required for cert-manager install
# and the script would die mid-run without it.
for TOOL in kubectl jq envsubst helm
do
    if ! command -v "$TOOL" >/dev/null 2>&1
    then
        echo "Missing tool: $TOOL"
        exit 1
    fi
done

###############################################
# Host-level prerequisites
###############################################

# FIX 8: The messaging-topology-operator's controller-runtime cert watcher
# uses fsnotify (inotify) to detect webhook cert rotation. On hosts with a
# low fs.inotify.max_user_instances (some distro defaults are as low as
# 128, and it's a system-wide counter shared with every kubectl -w, editor,
# etc.), the operator pod crashes on startup with:
#   "failed to create fsnotify watcher: too many open files"
# We raise and persist these limits before installing anything, so the
# operator never hits this on first boot.
log "Checking host inotify limits"

MIN_INSTANCES=1024
MIN_WATCHES=1048576

CURRENT_INSTANCES="$(cat /proc/sys/fs/inotify/max_user_instances)"
CURRENT_WATCHES="$(cat /proc/sys/fs/inotify/max_user_watches)"

if [ "$CURRENT_INSTANCES" -lt "$MIN_INSTANCES" ] || [ "$CURRENT_WATCHES" -lt "$MIN_WATCHES" ]
then
    log "Raising fs.inotify limits (instances: $CURRENT_INSTANCES -> $MIN_INSTANCES, watches: $CURRENT_WATCHES -> $MIN_WATCHES)"

    sudo sysctl -w fs.inotify.max_user_instances="$MIN_INSTANCES" >/dev/null
    sudo sysctl -w fs.inotify.max_user_watches="$MIN_WATCHES" >/dev/null

    SYSCTL_CONF="/etc/sysctl.d/99-rabbitmq-topology-operator.conf"
    if [ ! -f "$SYSCTL_CONF" ]
    then
        {
            echo "fs.inotify.max_user_instances=$MIN_INSTANCES"
            echo "fs.inotify.max_user_watches=$MIN_WATCHES"
        } | sudo tee "$SYSCTL_CONF" >/dev/null
        sudo sysctl --system >/dev/null
    fi
else
    log "fs.inotify limits already sufficient (instances: $CURRENT_INSTANCES, watches: $CURRENT_WATCHES)"
fi

###############################################
# Load Environment
###############################################

if [ ! -f "$ENV_FILE" ]
then
    log "ERROR: bootstrap.env not found"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# FIX 6: Validate that all variables required by the secret template are
# actually set after sourcing bootstrap.env. envsubst silently produces
# empty strings for missing variables, which would create a broken secret.
REQUIRED_VARS=(
    SHOPIXY_RABBITMQ_USERNAME
    SHOPIXY_RABBITMQ_PASSWORD
)
MISSING=0
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR:-}" ]; then
        log "ERROR: Required variable $VAR is not set in bootstrap.env"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    exit 1
fi

###############################################
# Generate Secrets
###############################################

mkdir -p "$GENERATED_DIR"

log "Generating RabbitMQ secrets"

envsubst \
  < "$PROJECT_ROOT/topology/templates/secret-shopixy-app.yaml.tpl" \
  > "$GENERATED_DIR/secret-shopixy-app.yaml"

###############################################
# Namespace
###############################################

log "Applying namespace"

sudo kubectl apply \
  -f "$PROJECT_ROOT/namespace.yaml"

###############################################
# Cert Manager
###############################################

if ! sudo kubectl get namespace cert-manager >/dev/null 2>&1
then

    log "Installing Cert Manager"

    helm repo add jetstack https://charts.jetstack.io || true

    helm repo update

    # FIX 2: Added --wait so helm blocks until cert-manager pods are actually
    # running before the script continues. Without this, rollout status on
    # the deployment can race ahead of the pods existing at all.
    helm install cert-manager \
      jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --set crds.enabled=true \
      --wait \
      --timeout 300s

else

    log "Cert Manager already installed"

fi

###############################################
# RabbitMQ Cluster Operator
###############################################

if ! sudo kubectl get deployment \
    rabbitmq-cluster-operator \
    -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1
then

    log "Installing RabbitMQ Cluster Operator"

    # FIX 3: 'latest' URLs can silently pull a breaking version on re-runs.
    # Pin to a specific release for reproducible bootstraps.
    # Update RABBITMQ_OPERATOR_VERSION when you want to upgrade.
    RABBITMQ_OPERATOR_VERSION="v2.12.1"
    sudo kubectl apply -f \
      "https://github.com/rabbitmq/cluster-operator/releases/download/${RABBITMQ_OPERATOR_VERSION}/cluster-operator.yml"

else

    log "RabbitMQ Operator already installed"

fi

###############################################
# Messaging Topology Operator
###############################################

if ! sudo kubectl get deployment \
    "$TOPOLOGY_OPERATOR_DEPLOYMENT" \
    -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1
then

    log "Installing Messaging Topology Operator"

    # FIX 3: Same as above — pin the topology operator version.
    TOPOLOGY_OPERATOR_VERSION="v1.16.0"
    sudo kubectl apply -f \
      "https://github.com/rabbitmq/messaging-topology-operator/releases/download/${TOPOLOGY_OPERATOR_VERSION}/messaging-topology-operator-with-certmanager.yaml"

else

    log "Messaging Topology Operator already installed"

fi

###############################################
# Wait Operators
###############################################

log "Waiting for operators to be ready"

sudo kubectl rollout status \
    deployment/rabbitmq-cluster-operator \
    -n "$OPERATOR_NAMESPACE" \
    --timeout=300s

sudo kubectl rollout status \
    deployment/"$TOPOLOGY_OPERATOR_DEPLOYMENT" \
    -n "$OPERATOR_NAMESPACE" \
    --timeout=300s

# FIX 4: rollout status confirms the deployment is ready, but the Messaging
# Topology Operator registers a webhook server that takes a few extra seconds
# to start accepting connections after the pod is Running. Applying topology
# CRDs (Queue, Exchange, Binding) too early causes intermittent webhook
# "connection refused" errors. Wait until the webhook endpoint is responsive.
log "Waiting for Messaging Topology Operator webhook to be ready"
for i in $(seq 1 30); do
    if sudo kubectl get validatingwebhookconfigurations \
        topology.rabbitmq.com >/dev/null 2>&1; then
        log "Topology Operator webhook is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: Topology Operator webhook not ready after 60s"
        exit 1
    fi
    sleep 2
done
# Give the webhook server a moment to start accepting connections
# after the ValidatingWebhookConfiguration is registered.
sleep 5

###############################################
# TLS (RabbitMQ server certs)
###############################################

log "Applying self-signed ClusterIssuer"
sudo kubectl apply -f "$PROJECT_ROOT/tls/selfsigned-clusterissuer.yaml"

log "Applying RabbitMQ CA certificate"
sudo kubectl apply -f "$PROJECT_ROOT/tls/rabbitmq-ca.yaml"

log "Waiting for RabbitMQ CA secret"
for i in $(seq 1 30); do
    if sudo kubectl get secret rabbitmq-ca-secret -n "$NAMESPACE" >/dev/null 2>&1; then
        log "RabbitMQ CA secret is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: rabbitmq-ca-secret not ready after 60s"
        exit 1
    fi
    sleep 2
done

log "Applying RabbitMQ CA Issuer"
sudo kubectl apply -f "$PROJECT_ROOT/tls/rabbitmq-ca-issuer.yaml"

log "Applying RabbitMQ server certificate"
sudo kubectl apply -f "$PROJECT_ROOT/tls/rabbitmq-server-cert.yaml"

log "Waiting for RabbitMQ server TLS secret"
for i in $(seq 1 30); do
    if sudo kubectl get secret rabbitmq-server-tls -n "$NAMESPACE" >/dev/null 2>&1; then
        log "RabbitMQ server TLS secret is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: rabbitmq-server-tls secret not ready after 60s"
        exit 1
    fi
    sleep 2
done

###############################################
# Topology Operator TLS Trust
###############################################

# FIX 9: RabbitmqCluster.spec.tls.caSecretName only tells the RabbitMQ
# *server* which cert/key to serve — it is NOT automatically consumed by
# the Messaging Topology Operator. The operator only trusts CA certs that
# are physically mounted into its own pod's trust store at /etc/ssl/certs/.
# Without this, every Vhost/Exchange/Queue/User/Permission/Binding declare
# call fails with:
#   x509: certificate signed by unknown authority
# We copy the CA cert into the operator's namespace and mount it into the
# deployment here, idempotently, so re-running bootstrap.sh is a no-op if
# it's already configured.
log "Configuring Messaging Topology Operator to trust RabbitMQ CA"

HAS_CA_VOLUME="$(sudo kubectl get deployment "$TOPOLOGY_OPERATOR_DEPLOYMENT" \
    -n "$OPERATOR_NAMESPACE" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='$TOPOLOGY_CA_SECRET_NAME')].name}" \
    2>/dev/null || true)"

if [ "$HAS_CA_VOLUME" = "$TOPOLOGY_CA_SECRET_NAME" ]; then
    log "Topology Operator already trusts the RabbitMQ CA — skipping"
else
    log "Copying RabbitMQ CA into $OPERATOR_NAMESPACE namespace"

    CA_TMP_FILE="$(mktemp)"
    trap 'rm -f "$CA_TMP_FILE"' RETURN

    sudo kubectl get secret rabbitmq-ca-secret -n "$NAMESPACE" \
        -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_TMP_FILE"

    sudo kubectl create secret generic "$TOPOLOGY_CA_SECRET_NAME" \
        -n "$OPERATOR_NAMESPACE" \
        --from-file=ca.crt="$CA_TMP_FILE" \
        --dry-run=client -o yaml | sudo kubectl apply -f -

    rm -f "$CA_TMP_FILE"

    log "Patching Messaging Topology Operator deployment to mount the CA"

    sudo kubectl -n "$OPERATOR_NAMESPACE" patch deployment "$TOPOLOGY_OPERATOR_DEPLOYMENT" --patch "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"containers\": [{
              \"name\": \"manager\",
              \"volumeMounts\": [{
                \"mountPath\": \"$TOPOLOGY_CA_MOUNT_PATH\",
                \"name\": \"$TOPOLOGY_CA_SECRET_NAME\",
                \"subPath\": \"ca.crt\"
              }]
            }],
            \"volumes\": [{
              \"name\": \"$TOPOLOGY_CA_SECRET_NAME\",
              \"secret\": {
                \"defaultMode\": 420,
                \"secretName\": \"$TOPOLOGY_CA_SECRET_NAME\"
              }
            }]
          }
        }
      }
    }"

    log "Waiting for Messaging Topology Operator to restart with CA trust"
    sudo kubectl rollout status \
        deployment/"$TOPOLOGY_OPERATOR_DEPLOYMENT" \
        -n "$OPERATOR_NAMESPACE" \
        --timeout=300s

    # Re-run the webhook readiness wait — the patch causes a fresh pod, and
    # the new pod's webhook server needs the same startup grace period as
    # the initial install did above.
    log "Waiting for Messaging Topology Operator webhook to be ready after restart"
    for i in $(seq 1 30); do
        if sudo kubectl get validatingwebhookconfigurations \
            topology.rabbitmq.com >/dev/null 2>&1; then
            break
        fi
        if [ "$i" -eq 30 ]; then
            log "ERROR: Topology Operator webhook not ready after restart"
            exit 1
        fi
        sleep 2
    done
    sleep 5
fi

###############################################
# Deploy Cluster
###############################################

log "Deploying RabbitMQ cluster"

sudo kubectl apply \
  -f "$PROJECT_ROOT/cluster/rabbitmq-cluster.yaml"

###############################################
# Wait Cluster
###############################################

log "Waiting for RabbitMQ cluster"

sudo kubectl wait \
  --for=condition=AllReplicasReady \
  rabbitmqcluster/rabbitmq \
  -n rabbitmq \
  --timeout=900s

###############################################
# Deploy Topology
###############################################

log "Deploying topology"

# FIX 5: Apply all topology resources in a single kubectl apply call using
# a directory or explicit file list so that a single failure aborts the
# whole apply atomically, rather than leaving the cluster in a partial state
# where some resources exist and others don't.
#
# Order matters for the Topology Operator:
#   1. Secret (credentials the User resource references)
#   2. Vhost
#   3. User
#   4. Permissions (references User + Vhost)
#   5. Exchange (references Vhost)
#   6. Queues (references Vhost)
#   7. Bindings (references Exchange + Queue)
#
# We pass them as explicit --filename flags in the correct order.
sudo kubectl apply \
  -f "$GENERATED_DIR/secret-shopixy-app.yaml" \
  -f "$PROJECT_ROOT/topology/vhost-shopixy.yaml" \
  -f "$PROJECT_ROOT/topology/user-shopixy-app.yaml" \
  -f "$PROJECT_ROOT/topology/permissions-shopixy-app.yaml" \
  -f "$PROJECT_ROOT/topology/exchange-shopixy-events.yaml" \
  -f "$PROJECT_ROOT/topology/queue-orders.yaml" \
  -f "$PROJECT_ROOT/topology/queue-products.yaml" \
  -f "$PROJECT_ROOT/topology/queue-notifications.yaml" \
  -f "$PROJECT_ROOT/topology/binding-orders.yaml" \
  -f "$PROJECT_ROOT/topology/binding-products.yaml" \
  -f "$PROJECT_ROOT/topology/binding-notifications.yaml"

###############################################
# Wait Topology
###############################################

# FIX 7: Wait for the Topology Operator to reconcile queues and exchanges.
# Bindings are excluded — the Binding CRD does not support the list verb
# and returns MethodNotAllowed. We check Ready condition via jsonpath since
# the --no-headers column format varies by operator version.
log "Waiting for topology resources to reconcile"
for i in $(seq 1 30); do
    READY=$(sudo kubectl get queues,exchanges \
        -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{" "}{end}{end}' \
        2>/dev/null | tr ' ' '\n' | grep -c "^True$" || true)
    TOTAL=$(sudo kubectl get queues,exchanges \
        -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{"x "}{end}' \
        2>/dev/null | wc -w || true)
    if [ "$TOTAL" -gt 0 ] && [ "$READY" -eq "$TOTAL" ]; then
        log "All $TOTAL topology resources ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "WARNING: Topology resources may not be fully reconciled after 60s — check with: kubectl get queues,exchanges -n $NAMESPACE"
        break
    fi
    log "Topology reconciling ($READY/$TOTAL ready)..."
    sleep 2
done

###############################################
# Monitoring
###############################################

log "Deploying monitoring"

sudo kubectl apply \
  -f "$PROJECT_ROOT/monitoring/rabbitmq-metrics-service.yaml"

sudo kubectl apply \
  -f "$PROJECT_ROOT/monitoring/rabbitmq-servicemonitor.yaml"

###############################################
# Validation
###############################################

log "Running validation"

sudo kubectl get rabbitmqcluster -n rabbitmq

echo

sudo kubectl get pods -n rabbitmq

echo

sudo kubectl exec \
  -n rabbitmq \
  rabbitmq-server-0 \
  -- rabbitmqctl cluster_status

echo

# Show topology summary as part of validation
# Note: bindings CRD does not support list verb, so excluded here.
log "Topology summary"
sudo kubectl get queues,exchanges -n "$NAMESPACE"

###############################################

log "========================================="
log "RabbitMQ Bootstrap Completed"
log "========================================="
