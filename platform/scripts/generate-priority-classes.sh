#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/renderer.sh"

log_info "========================================="
log_info "PriorityClass Generator"
log_info "========================================="

TEMPLATE="$ROOT_DIR/priority-classes/templates/priorityclass-template.yaml"

OUTPUT=$(generated_dir priority-classes)

mkdir -p "$OUTPUT"

GENERATED=()

for SERVICE in $(list_services)
do

    PRIORITY_PROFILE=$(service_value "$SERVICE" priorityClass)

    if [[ " ${GENERATED[*]} " =~ " ${PRIORITY_PROFILE} " ]]
    then
        continue
    fi

    GENERATED+=("$PRIORITY_PROFILE")

    PRIORITY_NAME=$(priority_class_value "$PRIORITY_PROFILE" "priority.name")
    PRIORITY_VALUE=$(priority_class_value "$PRIORITY_PROFILE" "value")
    GLOBAL_DEFAULT=$(priority_class_value "$PRIORITY_PROFILE" "globalDefault")
    DESCRIPTION=$(priority_class_value "$PRIORITY_PROFILE" "description")

    OUTPUT_FILE="$OUTPUT/$PRIORITY_NAME.yaml"

    render_template \
        "$TEMPLATE" \
        "$OUTPUT_FILE" \
        priority_name "$PRIORITY_NAME" \
        priority_value "$PRIORITY_VALUE" \
        global_default "$GLOBAL_DEFAULT" \
        description "$DESCRIPTION"

    log_info "Generated: $OUTPUT_FILE"

done
