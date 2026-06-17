#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/docker-compose.template.yml"
FIREWALL_TEMPLATE="$REPO_ROOT/config/docker-compose.firewall.template.yml"
ENVS_DIR="$REPO_ROOT/envs"
SECRETS_DIR="$REPO_ROOT/secrets"

ENV_NAME=""
REPO_PATH=""
SSH_PORT=""
PUBKEY=""
IMAGE_TAG="claude-dev:latest"
FIREWALL=0

usage() {
	cat <<'EOF'
Usage: new-env.sh --repo <path> [--name <name>] [--port <port>] [--pubkey <path>] [--image <tag>]

  --repo    Absolute path (inside WSL) to the repository to mount. Required.
  --name    Environment name (default: basename of --repo).
  --port    Host SSH port to expose (default: auto, starting at 2200).
  --pubkey  SSH public key to authorize (default: ~/.ssh/id_ed25519.pub then id_rsa.pub).
  --image   Base image tag (default: claude-dev:latest).
  --firewall Lock down egress to an allowlist (opt-in profile for unattended runs).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo) REPO_PATH="${2:-}"; shift 2;;
		--name) ENV_NAME="${2:-}"; shift 2;;
		--port) SSH_PORT="${2:-}"; shift 2;;
		--pubkey) PUBKEY="${2:-}"; shift 2;;
		--image) IMAGE_TAG="${2:-}"; shift 2;;
		--firewall) FIREWALL=1; shift;;
		-h|--help) usage; exit 0;;
		*) echo "Unknown argument: $1" >&2; usage; exit 1;;
	esac
done

[ -n "$REPO_PATH" ] || { echo "Error: --repo is required" >&2; usage; exit 1; }
[ -d "$REPO_PATH" ] || { echo "Error: repo path does not exist: $REPO_PATH" >&2; exit 1; }
REPO_PATH="$(cd "$REPO_PATH" && pwd)"

[ -n "$ENV_NAME" ] || ENV_NAME="$(basename "$REPO_PATH")"
ENV_NAME="$(printf '%s' "$ENV_NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-_')"
[ -n "$ENV_NAME" ] || { echo "Error: could not derive a valid env name" >&2; exit 1; }

mkdir -p "$ENVS_DIR" "$SECRETS_DIR"

if [ -z "$PUBKEY" ]; then
	for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
		[ -f "$cand" ] && PUBKEY="$cand" && break
	done
fi
[ -n "$PUBKEY" ] && [ -f "$PUBKEY" ] || {
	echo "Error: no SSH public key found. Pass --pubkey <file> or run: ssh-keygen -t ed25519" >&2
	exit 1
}

if [ -z "$SSH_PORT" ]; then
	SSH_PORT=2200
	if compgen -G "$ENVS_DIR/*.compose.yml" >/dev/null 2>&1; then
		used_max="$(grep -rhoE '127\.0\.0\.1:[0-9]+:22' "$ENVS_DIR"/*.compose.yml \
			| grep -oE '[0-9]+:22' | cut -d: -f1 | sort -n | tail -1 || true)"
		[ -n "$used_max" ] && SSH_PORT=$((used_max + 1))
	fi
fi

AUTHKEYS_PATH="$SECRETS_DIR/$ENV_NAME.authorized_keys"
cp "$PUBKEY" "$AUTHKEYS_PATH"
chmod 600 "$AUTHKEYS_PATH"

render() {
	sed \
		-e "s|\${ENV_NAME}|$ENV_NAME|g" \
		-e "s|\${REPO_PATH}|$REPO_PATH|g" \
		-e "s|\${SSH_PORT}|$SSH_PORT|g" \
		-e "s|\${IMAGE_TAG}|$IMAGE_TAG|g" \
		-e "s|\${AUTHKEYS_PATH}|$AUTHKEYS_PATH|g" \
		"$1"
}

COMPOSE_FILE="$ENVS_DIR/$ENV_NAME.compose.yml"
OVERLAY_FILE="$ENVS_DIR/$ENV_NAME.firewall.yml"
render "$TEMPLATE" > "$COMPOSE_FILE"

COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [ "$FIREWALL" = "1" ]; then
	render "$FIREWALL_TEMPLATE" > "$OVERLAY_FILE"
	COMPOSE_ARGS+=(-f "$OVERLAY_FILE")
else
	rm -f "$OVERLAY_FILE"
fi

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
	echo "Image '$IMAGE_TAG' not found; building it now..."
	docker build -t "$IMAGE_TAG" "$REPO_ROOT"
fi

docker compose "${COMPOSE_ARGS[@]}" up -d

cat <<EOF

Environment '$ENV_NAME' is up.

  Container : claude-$ENV_NAME
  Repo      : $REPO_PATH  ->  /workspaces/$ENV_NAME
  SSH       : node@127.0.0.1  port $SSH_PORT
  Volume    : claude-$ENV_NAME  (holds /home/node/.claude - sessions + auth)
  Egress    : $([ "$FIREWALL" = "1" ] && echo "LOCKED (allowlist firewall)" || echo "open")
  Perms     : auto mode + guardrails (seeded on first run into the volume)

Add this SSH connection in the Claude desktop app:
  SSH Host      : node@127.0.0.1
  SSH Port      : $SSH_PORT
  Identity File : ${PUBKEY%.pub}

Recreate later without losing history:  scripts/rebuild.sh $ENV_NAME
EOF
