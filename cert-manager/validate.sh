#!/usr/bin/env bash

set -Eeuo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo
echo "========================================="
echo " Cert Manager Validation"
echo "========================================="
echo

###############################################
# Namespace
###############################################

sudo kubectl get ns cert-manager >/dev/null

echo "[OK] Namespace"

###############################################
# Deployments
###############################################

for DEPLOYMENT in \
    cert-manager \
    cert-manager-webhook \
    cert-manager-cainjector
do

    AVAILABLE=$(
       sudo kubectl get deployment "$DEPLOYMENT" \
            -n cert-manager \
            -o jsonpath='{.status.availableReplicas}'
    )

    [ "${AVAILABLE:-0}" -ge 1 ] || {
        echo "[ERROR] Deployment not available: $DEPLOYMENT"
        exit 1
    }

    echo "[OK] $DEPLOYMENT"

done

###############################################
# Pods Ready
###############################################

sudo kubectl wait \
    --for=condition=Ready \
    pod \
    --all \
    -n cert-manager \
    --timeout=120s >/dev/null

echo "[OK] All Pods Ready"

###############################################
# CRDs
###############################################

for CRD in \
    certificates.cert-manager.io \
    certificaterequests.cert-manager.io \
    issuers.cert-manager.io \
    clusterissuers.cert-manager.io
do

    sudo kubectl get crd "$CRD" >/dev/null || {
        echo "[ERROR] Missing CRD: $CRD"
        exit 1
    }

    echo "[OK] $CRD"

done

###############################################
# Summary
###############################################

echo
sudo kubectl get pods -n cert-manager

echo
echo "========================================="
echo " Cert Manager Validation Completed"
echo "========================================="
echo
