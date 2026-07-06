#!/usr/bin/env bash

set -euo pipefail

echo "========================================="
echo "Platform Tool Validation"
echo "========================================="

for tool in kubectl yq awk sed grep; do

    if command -v "$tool" >/dev/null 2>&1; then

        printf "✓ %s\n" "$tool"

    else

        printf "✗ %s NOT FOUND\n" "$tool"
        exit 1

    fi

done

echo
echo "All required tools are available."
