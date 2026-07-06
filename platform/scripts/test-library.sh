#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/common.sh"

echo
echo "Profile"

profile_value ".platform.profile"

echo
echo "Environment"

profile_value ".environment.name"

echo
echo "Mongo Namespace"

service_value mongo namespace

echo
echo "Redis Tier"

service_value redis tier

echo
echo "Services"

list_services

echo
echo "Critical Large Request Memory"

resource_class_value critical-large "resources.requests.memory"

echo
echo "Critical Large Limit CPU"

resource_class_value critical-large "resources.limits.cpu"

echo
echo "Critical Large Default CPU"

limit_profile_value critical-large "limits.default.cpu"

echo
echo "Critical Large Max Memory"

limit_profile_value critical-large "limits.max.memory"

echo
echo "Renderer Library"

source "$ROOT_DIR/lib/renderer.sh"

echo "Loaded Successfully"


echo
echo "Mongo Limit Profile"

service_value mongo limitProfile

echo
echo "Grafana Limit Profile"

service_value grafana limitProfile

echo
echo "Critical Large Priority"

priority_class_value critical-large "value"

echo
echo "Monitoring Priority"

priority_class_value monitoring "value"
