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
WIN_KEY=""
IMAGE_TAG="claude-dev:latest"
FIREWALL=0

usage() {
	cat <<'EOF'
Usage: new-env.sh --repo <path> [--name <name>] [--port <port>] [--pubkey <path>]
                  [--win-key <path>] [--image <tag>] [--firewall]

  --repo     Absolute path (inside WSL) to the repository to mount. Required.
  --name     Environment name (default: basename of --repo).
  --port     Host SSH port to expose (default: auto, starting at 2200).
  --pubkey   Extra SSH public key to authorize (added to the auto-detected ones).
  --win-key  Windows SSH public key to authorize (default: auto-detected from the
             Windows user profile - this is the key the desktop app connects with).
  --image    Base image tag (default: claude-dev:latest).
  --firewall Lock down egress to an allowlist (opt-in profile for unattended runs).

By default this authorizes BOTH your WSL key (for `ssh` from inside WSL) and your
Windows key (what the Claude desktop app presents), so the connection just works.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo) REPO_PATH="${2:-}"; shift 2;;
		--name) ENV_NAME="${2:-}"; shift 2;;
		--port) SSH_PORT="${2:-}"; shift 2;;
		--pubkey) PUBKEY="${2:-}"; shift 2;;
		--win-key) WIN_KEY="${2:-}"; shift 2;;
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
# Display name: SSH-<RepoName>, capitalization preserved, dots/spaces -> dashes. This is
# the workspace folder + container name you see in the desktop app, so SSH containers sort
# together under "SSH-" and never collide with your local (non-SSH) projects.
ENV_NAME="${ENV_NAME//./-}"
ENV_NAME="$(printf '%s' "$ENV_NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9_-')"
case "$ENV_NAME" in
	SSH-*|ssh-*) ENV_NAME="SSH-${ENV_NAME#???-}" ;;
	*) ENV_NAME="SSH-$ENV_NAME" ;;
esac
[ -n "$ENV_NAME" ] && [ "$ENV_NAME" != "SSH-" ] || { echo "Error: could not derive a valid env name" >&2; exit 1; }
# Docker Compose requires the project name to be lowercase; derive it from the display name.
PROJECT_NAME="$(printf '%s' "$ENV_NAME" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$ENVS_DIR" "$SECRETS_DIR"

# --- Collect public keys to authorize -------------------------------------------------
# The Claude desktop app runs on Windows and connects with the *Windows* SSH key, while
# `ssh` from inside WSL uses the *WSL* key. We authorize whatever we can find of both, so
# the connection works no matter where you connect from. Keys are de-duplicated by content.
PUBKEYS=()
WIN_KEY_DETECTED=""   # remembered so we can print the right Identity File hint at the end
add_key() { if [ -n "${1:-}" ] && [ -f "$1" ]; then PUBKEYS+=("$1"); fi; }

# 1. WSL key (for `ssh` from within WSL / scripts)
add_key "$HOME/.ssh/id_ed25519.pub"
add_key "$HOME/.ssh/id_rsa.pub"

# 2. Windows key (what the desktop app presents) - explicit flag, else auto-detect
if [ -n "$WIN_KEY" ]; then
	add_key "$WIN_KEY"; WIN_KEY_DETECTED="$WIN_KEY"
else
	win_profile=""
	if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
		wp="$( (cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %USERPROFILE%') 2>/dev/null | tr -d '\r\n')"
		[ -n "$wp" ] && win_profile="$(wslpath "$wp" 2>/dev/null || true)"
	fi
	if [ -n "$win_profile" ] && [ -d "$win_profile/.ssh" ]; then
		for c in "$win_profile/.ssh/id_ed25519.pub" "$win_profile/.ssh/id_rsa.pub"; do
			[ -f "$c" ] && { add_key "$c"; [ -z "$WIN_KEY_DETECTED" ] && WIN_KEY_DETECTED="$c"; }
		done
	else
		# Fallback: scan real Windows user profiles (skip system ones)
		for d in /mnt/c/Users/*/.ssh; do
			case "$d" in */Public/.ssh|*/Default/.ssh|*/"Default User"/.ssh|*/"All Users"/.ssh) continue;; esac
			for c in "$d/id_ed25519.pub" "$d/id_rsa.pub"; do
				[ -f "$c" ] && { add_key "$c"; [ -z "$WIN_KEY_DETECTED" ] && WIN_KEY_DETECTED="$c"; }
			done
		done
	fi
fi

# 3. Any extra key the user passed explicitly
add_key "$PUBKEY"

[ "${#PUBKEYS[@]}" -gt 0 ] || {
	echo "Error: no SSH public key found. Pass --pubkey <file>/--win-key <file>, or run: ssh-keygen -t ed25519" >&2
	exit 1
}

if [ -z "$SSH_PORT" ]; then
	SSH_PORT=2200
	if compgen -G "$ENVS_DIR/*.compose.yml" >/dev/null 2>&1; then
		used_max="$(grep -rhoE '127\.0\.0\.1:[0-9]+:22' "$ENVS_DIR"/*.compose.yml \
			| cut -d: -f2 | sort -n | tail -1 || true)"
		[ -n "$used_max" ] && SSH_PORT=$((used_max + 1))
	fi
fi

AUTHKEYS_PATH="$SECRETS_DIR/$ENV_NAME.authorized_keys"
: > "$AUTHKEYS_PATH"
chmod 600 "$AUTHKEYS_PATH"
declare -A _seen_keys=()
AUTH_COUNT=0
for k in "${PUBKEYS[@]}"; do
	line="$(tr -d '\r' < "$k")"
	blob="$(awk '{print $2}' <<<"$line")"   # de-dupe on the key material, not the path
	[ -n "$blob" ] || continue
	[ -n "${_seen_keys[$blob]:-}" ] && continue
	_seen_keys[$blob]=1
	printf '%s\n' "$line" >> "$AUTHKEYS_PATH"
	AUTH_COUNT=$((AUTH_COUNT + 1))
	echo "  authorizing key: $k"
done

render() {
	sed \
		-e "s|\${PROJECT_NAME}|$PROJECT_NAME|g" \
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

# Identity File hint: the desktop app needs the *Windows* private key. If we detected one,
# show it in Windows path form (C:\Users\...); otherwise fall back to the WSL key.
if [ -n "$WIN_KEY_DETECTED" ] && command -v wslpath >/dev/null 2>&1; then
	IDENTITY_HINT="$(wslpath -w "${WIN_KEY_DETECTED%.pub}" 2>/dev/null || echo "${WIN_KEY_DETECTED%.pub}")"
else
	IDENTITY_HINT="$HOME/.ssh/id_ed25519  (WSL key - for the desktop app, use your Windows %USERPROFILE%\\.ssh key)"
fi

cat <<EOF

Environment '$ENV_NAME' is up.  ($AUTH_COUNT SSH key(s) authorized)

  Container : claude-$ENV_NAME
  Repo      : $REPO_PATH  ->  /workspaces/$ENV_NAME
  SSH       : node@127.0.0.1  port $SSH_PORT
  Volume    : claude-$ENV_NAME  (holds /home/node/.claude - sessions + auth)
  Egress    : $([ "$FIREWALL" = "1" ] && echo "LOCKED (allowlist firewall)" || echo "open")
  Perms     : auto mode + guardrails (seeded on first run into the volume)

Add this SSH connection in the Claude desktop app:
  SSH Host      : node@127.0.0.1
  SSH Port      : $SSH_PORT
  Identity File : $IDENTITY_HINT
  Folder        : /workspaces/$ENV_NAME

Next steps:
  1. Enable git inside the container:  scripts/setup-git-auth.sh $ENV_NAME
  2. First connect (accept fingerprint) from PowerShell:
       ssh -p $SSH_PORT node@127.0.0.1
  3. Recreate later without losing history:  scripts/rebuild.sh $ENV_NAME
EOF
