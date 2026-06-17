#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-}"

[ -n "$NAME" ] || { echo "Usage: rebuild.sh <env-name> [--image]" >&2; exit 1; }

COMPOSE_FILE="$REPO_ROOT/envs/$NAME.compose.yml"
OVERLAY_FILE="$REPO_ROOT/envs/$NAME.firewall.yml"
[ -f "$COMPOSE_FILE" ] || {
	echo "No environment '$NAME' (missing $COMPOSE_FILE). Run new-env.sh first." >&2
	exit 1
}

if [ "${2:-}" = "--image" ]; then
	echo "Rebuilding base image claude-dev:latest..."
	docker build -t claude-dev:latest "$REPO_ROOT"
fi

COMPOSE_ARGS=(-f "$COMPOSE_FILE")
[ -f "$OVERLAY_FILE" ] && COMPOSE_ARGS+=(-f "$OVERLAY_FILE")

docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate

echo "Recreated claude-$NAME. The 'claude-$NAME' volume (sessions + auth) was preserved."
