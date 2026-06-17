#!/usr/bin/env bash
# Enable git (clone / fetch / pull / push) *inside* a container, securely.
#
# What it does:
#   1. Points git at a credential store on the persistent volume (~/.claude/.git-credentials).
#   2. Writes a GitHub token into that store (mode 600). The token is read over stdin so it
#      never appears in the process list, your shell history, or this script's arguments.
#   3. Sets your git commit identity (name + email).
#
# Why it's safe: the token lives ONLY on the per-repo volume (never in the image, never in
# git), is readable only by the node user, and pushes still require your approval via the
# auto-mode guardrails. Each container holds just its own credential.
#
# Token source (first that works): --stdin | --token-cmd <cmd> | GitHub CLI `gh auth token`.
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: setup-git-auth.sh <env-name> [--name <git name>] [--email <git email>]
                         [--gh <path-to-gh>] [--token-cmd "<command>"] [--stdin]

  <env-name>    The environment (e.g. SSH-WTA-Ramen). Case-insensitive.
  --name        Git commit author name  (default: your host git config, else GitHub login).
  --email       Git commit author email (default: your host git config, else GitHub noreply).
  --gh          Path to the GitHub CLI  (default: auto-detect Windows gh.exe or Linux gh).
  --token-cmd   Command that prints a token on stdout (e.g. for a PAT: 'cat ~/my-pat.txt').
  --stdin       Read the token from this script's stdin instead of calling gh.

Examples:
  scripts/setup-git-auth.sh SSH-WTA-Ramen
  echo "$MY_PAT" | scripts/setup-git-auth.sh SSH-WTA-Ramen --stdin
EOF
}

ENV_NAME=""; GIT_NAME=""; GIT_EMAIL=""; GH=""; TOKEN_CMD=""; USE_STDIN=0
while [ $# -gt 0 ]; do
	case "$1" in
		--name) GIT_NAME="${2:-}"; shift 2;;
		--email) GIT_EMAIL="${2:-}"; shift 2;;
		--gh) GH="${2:-}"; shift 2;;
		--token-cmd) TOKEN_CMD="${2:-}"; shift 2;;
		--stdin) USE_STDIN=1; shift;;
		-h|--help) usage; exit 0;;
		-*) echo "Unknown argument: $1" >&2; usage; exit 1;;
		*) [ -z "$ENV_NAME" ] && ENV_NAME="$1" || { echo "Unexpected argument: $1" >&2; exit 1; }; shift;;
	esac
done
[ -n "$ENV_NAME" ] || { echo "Error: <env-name> is required" >&2; usage; exit 1; }

# Resolve the real container name (case-insensitive match on claude-<env>).
CONTAINER="$(docker ps --format '{{.Names}}' | grep -ix "claude-${ENV_NAME#claude-}" || true)"
[ -n "$CONTAINER" ] || {
	echo "Error: no running container matches 'claude-${ENV_NAME#claude-}'." >&2
	echo "Running environments:" >&2
	docker ps --filter "name=claude-" --format '  {{.Names}}' >&2
	exit 1
}

# --- Obtain a token -------------------------------------------------------------------
get_token() {
	if [ "$USE_STDIN" = "1" ]; then cat; return; fi
	if [ -n "$TOKEN_CMD" ]; then eval "$TOKEN_CMD"; return; fi
	# Auto-detect GitHub CLI: explicit --gh, then Windows gh.exe, then Linux gh.
	local gh="$GH"
	[ -n "$gh" ] || for c in "/mnt/c/Program Files/GitHub CLI/gh.exe" gh.exe gh; do
		command -v "$c" >/dev/null 2>&1 && { gh="$c"; break; }
		[ -x "$c" ] && { gh="$c"; break; }
	done
	[ -n "$gh" ] || { echo "Error: GitHub CLI not found. Use --gh, --token-cmd or --stdin." >&2; return 1; }
	GH_RESOLVED="$gh"
	"$gh" auth token 2>/dev/null
}

# Identity defaults: prefer values already on this host, else ask gh, else a noreply address.
gh_field() { [ -n "${GH_RESOLVED:-}" ] && "$GH_RESOLVED" api user -q "$1" 2>/dev/null || true; }
[ -n "$GIT_NAME" ]  || GIT_NAME="$(git config --global user.name  2>/dev/null || true)"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"

echo "Provisioning git auth in $CONTAINER ..."
TOKEN="$(get_token || true)"
[ -n "$TOKEN" ] || { echo "Error: could not obtain a token." >&2; exit 1; }

# Fill any missing identity from the GitHub account the token belongs to.
if [ -z "$GIT_NAME" ];  then GIT_NAME="$(gh_field .login)"; fi
if [ -z "$GIT_EMAIL" ]; then
	login="$(gh_field .login)"
	GIT_EMAIL="${login:+${login}@users.noreply.github.com}"
fi

# --- Write credential + identity into the container's persistent volume ---------------
printf '%s\n' "$TOKEN" | docker exec -i -u node "$CONTAINER" bash -lc '
	set -e
	umask 077
	IFS= read -r TOK || true
	[ -n "$TOK" ] || { echo "no token received over stdin" >&2; exit 1; }
	git config --global credential.helper "store --file=$HOME/.claude/.git-credentials"
	printf "https://x-access-token:%s@github.com\n" "$TOK" > "$HOME/.claude/.git-credentials"
	chmod 600 "$HOME/.claude/.git-credentials"
'
docker exec -u node "$CONTAINER" bash -lc "
	git config --global user.name  \"$GIT_NAME\"
	git config --global user.email \"$GIT_EMAIL\"
"

# --- Verify against the mounted repo's remote (non-destructive) -----------------------
WS="$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$CONTAINER" | grep '^/workspaces/' | head -1)"
echo -n "Verifying authenticated access"
if [ -n "$WS" ] && docker exec -u node "$CONTAINER" bash -lc "cd '$WS' && GIT_TERMINAL_PROMPT=0 git ls-remote --heads origin >/dev/null 2>&1"; then
	echo " ... OK"
else
	echo " ... could not confirm (the token may lack access, or origin is unreachable)."
fi

cat <<EOF

git is ready in $CONTAINER:
  identity     : $GIT_NAME <$GIT_EMAIL>
  credentials  : /home/node/.claude/.git-credentials (mode 600, on the persistent volume)
  helper       : store (persists across scripts/rebuild.sh via the symlinked ~/.gitconfig)

Reminder: commit and push require your approval; force-push / hard-reset are blocked.
EOF
