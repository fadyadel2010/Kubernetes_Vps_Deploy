#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log_info() {
  echo "[INFO] $1"
}

log_ok() {
  echo "[OK] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_skip() {
  echo "[SKIP] $1"
}

require_binary() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1
  then
    echo "[ERROR] Missing dependency: $bin"
    exit 1
  fi
}

wait_for_rollout() {
  local kind="$1"
  local name="$2"
  local namespace="$3"

  kubectl rollout status \
    "$kind/$name" \
    -n "$namespace" \
    --timeout=20m
}

get_admin_user() {
  local secret_name="shopixy-search-admin-password"
  kubectl get secret \
    "$secret_name" \
    -n opensearch \
    -o jsonpath='{.data.username}' \
    | base64 -d
}

get_admin_password() {
  local secret_name="shopixy-search-admin-password"
  kubectl get secret \
    "$secret_name" \
    -n opensearch \
    -o jsonpath='{.data.password}' \
    | base64 -d
}
