#!/usr/bin/env bash

set -euo pipefail

echo "========================================="
echo "Installing Platform Dependencies"
echo "========================================="

install_yq() {

    if command -v yq >/dev/null 2>&1; then
        echo "✓ yq already installed"
        return
    fi

    echo "Installing yq..."

    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64

    sudo chmod +x /usr/local/bin/yq

    echo "✓ yq installed"
}

install_yq

echo
echo "Done."
