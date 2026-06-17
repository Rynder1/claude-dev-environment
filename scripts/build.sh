#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_TAG="${1:-claude-dev:latest}"

docker build -t "$IMAGE_TAG" "$REPO_ROOT"
echo "Built ${IMAGE_TAG}"
