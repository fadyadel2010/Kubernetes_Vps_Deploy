#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/renderer.sh"

log_info "========================================="
log_info "LimitRange Generator"
log_info "========================================="

TEMPLATE="$ROOT_DIR/limit-ranges/templates/limitrange-template.yaml"

OUTPUT=$(generated_dir limit-ranges)

for SERVICE in $(list_services)
do

    log_info "Generating LimitRange for: $SERVICE"

    NAMESPACE=$(service_value "$SERVICE" namespace)

    LIMIT_PROFILE=$(service_value "$SERVICE" limitProfile)

    DEFAULT_REQUEST_CPU=$(limit_profile_value "$LIMIT_PROFILE" "limits.defaultRequest.cpu")
    DEFAULT_REQUEST_MEMORY=$(limit_profile_value "$LIMIT_PROFILE" "limits.defaultRequest.memory")

    DEFAULT_CPU=$(limit_profile_value "$LIMIT_PROFILE" "limits.default.cpu")
    DEFAULT_MEMORY=$(limit_profile_value "$LIMIT_PROFILE" "limits.default.memory")

    MAX_CPU=$(limit_profile_value "$LIMIT_PROFILE" "limits.max.cpu")
    MAX_MEMORY=$(limit_profile_value "$LIMIT_PROFILE" "limits.max.memory")

    MIN_CPU=$(limit_profile_value "$LIMIT_PROFILE" "limits.min.cpu")
    MIN_MEMORY=$(limit_profile_value "$LIMIT_PROFILE" "limits.min.memory")

    OUTPUT_FILE="$OUTPUT/$SERVICE.yaml"

    render_template \
        "$TEMPLATE" \
        "$OUTPUT_FILE" \
        service "$SERVICE" \
        namespace "$NAMESPACE" \
        default_request_cpu "$DEFAULT_REQUEST_CPU" \
        default_request_memory "$DEFAULT_REQUEST_MEMORY" \
        default_cpu "$DEFAULT_CPU" \
        default_memory "$DEFAULT_MEMORY" \
        max_cpu "$MAX_CPU" \
        max_memory "$MAX_MEMORY" \
        min_cpu "$MIN_CPU" \
        min_memory "$MIN_MEMORY"

    log_info "Generated: $OUTPUT_FILE"

done
