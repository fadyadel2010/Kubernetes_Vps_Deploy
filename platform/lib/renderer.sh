#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HEADER="$ROOT_DIR/templates/header.txt"

render_template() {

    local template="$1"
    local output="$2"

    shift 2

    cat "$HEADER" > "$output"

    local tmp
    tmp=$(mktemp)

    cp "$template" "$tmp"

    while [[ $# -gt 0 ]]
    do
        local key="$1"
        local value="$2"

        sed -i \
            "s|{{[[:space:]]*$key[[:space:]]*}}|$value|g" \
            "$tmp"

        shift 2
    done

    cat "$tmp" >> "$output"

    rm -f "$tmp"
}
