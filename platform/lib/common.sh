#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROFILE="$ROOT_DIR/profiles/shopixy-production.yaml"
INVENTORY="$ROOT_DIR/inventory/services.yaml"

TEMPLATE_DIR="$ROOT_DIR/namespaces/templates"

OUTPUT_DIR="$ROOT_DIR/generated"

########################################
# Logging
########################################

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

########################################
# Validation
########################################

require_file() {

    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        exit 1
    fi
}

########################################
# Profile
########################################

profile_value() {

    local query="$1"

    yq "$query" "$PROFILE"
}

########################################
# Inventory
########################################

service_value() {

    local service="$1"
    local field="$2"

    yq ".services[] | select(.name == \"$service\") | .$field" "$INVENTORY"
}

########################################
# Templates
########################################

template_file() {

    local name="$1"

    echo "$TEMPLATE_DIR/$name"
}

########################################
# Generated Output
########################################

generated_dir() {

    local dir="$1"

    mkdir -p "$OUTPUT_DIR/$dir"

    echo "$OUTPUT_DIR/$dir"
}

########################################
# Services
########################################

list_services() {

    yq '.services[].name' "$INVENTORY"

}


########################################
# Resource Classes
########################################

resource_class_value() {

    local class="$1"
    local query="$2"

    yq ".$query" \
      "$ROOT_DIR/resource-classes/$class.yaml"

}

########################################
# Limit Profile
########################################

limit_profile_value() {

    local profile="$1"
    local query="$2"

    yq ".$query" \
      "$ROOT_DIR/limit-profiles/$profile.yaml"

}

########################################
# Priority Classes
########################################

priority_class_value() {

    local profile="$1"
    local query="$2"

    yq ".$query" \
        "$ROOT_DIR/priority-classes/$profile.yaml"

}
