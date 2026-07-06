#!/usr/bin/env bash

set -Eeuo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

###############################################
# Required Tools
###############################################

for TOOL in sudo kubectl helm
do
    if ! command -v "$TOOL" >/dev/null 2>&1
    then
        echo "Missing tool: $TOOL"
        exit 1
    fi
done

###############################################
# Cert Manager
###############################################

if ! sudo kubectl get ns cert-manager >/dev/null 2>&1
then

    log "Installing Cert Manager..."

    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true

    helm repo update

    helm install cert-manager \
        jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set crds.enabled=true \
        --version v1.18.2 \
        --wait \
        --timeout 300s

else

    log "Cert Manager already installed"

fi

###############################################
# Wait for Deployments
###############################################

for DEPLOYMENT in \
    cert-manager \
    cert-manager-webhook \
    cert-manager-cainjector
do

    log "Waiting for $DEPLOYMENT..."

   sudo kubectl rollout status \
        deployment/$DEPLOYMENT \
        -n cert-manager \
        --timeout=300s

done

echo
log "========================================="
log "Cert Manager Bootstrap Completed"
log "========================================="
