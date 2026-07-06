#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/common.sh"

log_info "========================================="
log_info "ResourceQuota Generator"
log_info "========================================="

TEMPLATE="$ROOT_DIR/resource-quotas/templates/resourcequota-template.yaml"

OUTPUT=$(generated_dir resource-quotas)

HEADER="$ROOT_DIR/templates/header.txt"

for SERVICE in $(list_services)
do

    log_info "Generating ResourceQuota for: $SERVICE"

    NAMESPACE=$(service_value "$SERVICE" namespace)

    RESOURCE_CLASS=$(service_value "$SERVICE" resourceClass)

    REQUEST_CPU=$(resource_class_value "$RESOURCE_CLASS" "resources.requests.cpu")
    REQUEST_MEMORY=$(resource_class_value "$RESOURCE_CLASS" "resources.requests.memory")

    LIMIT_CPU=$(resource_class_value "$RESOURCE_CLASS" "resources.limits.cpu")
    LIMIT_MEMORY=$(resource_class_value "$RESOURCE_CLASS" "resources.limits.memory")

    OUTPUT_FILE="$OUTPUT/$SERVICE.yaml"

    cat "$HEADER" > "$OUTPUT_FILE"

    sed \
      -e "s/{{ service }}/$SERVICE/g" \
      -e "s/{{ namespace }}/$NAMESPACE/g" \
      -e "s/{{ requests_cpu }}/$REQUEST_CPU/g" \
      -e "s/{{ requests_memory }}/$REQUEST_MEMORY/g" \
      -e "s/{{ limits_cpu }}/$LIMIT_CPU/g" \
      -e "s/{{ limits_memory }}/$LIMIT_MEMORY/g" \
      "$TEMPLATE" >> "$OUTPUT_FILE"

    log_info "Generated: $OUTPUT_FILE"

done
