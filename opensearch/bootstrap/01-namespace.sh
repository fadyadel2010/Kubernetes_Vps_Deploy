#!/usr/bin/env bash

set -euo pipefail

source scripts/common.sh

log_info "Checking namespace"

if sudo kubectl get namespace opensearch >/dev/null 2>&1
then
  log_skip "Namespace opensearch already exists"
else
  log_info "Creating namespace"
  sudo kubectl apply -f namespace.yaml
  log_ok "Namespace created"
fi
