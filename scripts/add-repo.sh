#!/usr/bin/env bash
# One command to go from a repo URL to a ready-to-connect container.
#
#   scripts/add-repo.sh <url | owner/repo | local-path> [name] [--firewall]
#
# It will:
#   1. Clone the repo into ~/code (skips if it's already there), OR use a local path as-is.
#   2. Create the container env (authorizes your WSL + Windows SSH keys).
#   3. Enable git inside the container (token on the volume, commit identity) - best effort.
#   4. Print the exact values to paste into the Claude desktop app.
#
# Examples:
#   scripts/add-repo.sh https://github.com/WiseTechGlobal/WTA.Ramen
#   scripts/add-repo.sh WiseTechGlobal/WTA.Ramen
#   scripts/add-repo.sh git@github.com:WiseTechGlobal/WTA.Ramen.git ramen
#   scripts/add-repo.sh ~/code/WTA.Ramen
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODE_DIR="${CODE_DIR:-$HOME/code}"   # where repos are cloned (override with CODE_DIR=...)

INPUT=""; NAME=""; FIREWALL=()
while [ $# -gt 0 ]; do
	case "$1" in
		--firewall) FIREWALL=(--firewall); shift;;
		-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
		-*) echo "Unknown option: $1" >&2; exit 1;;
		*) if [ -z "$INPUT" ]; then INPUT="$1"; elif [ -z "$NAME" ]; then NAME="$1"; else
			echo "Unexpected argument: $1" >&2; exit 1; fi; shift;;
	esac
done
[ -n "$INPUT" ] || { echo "Usage: add-repo.sh <url | owner/repo | local-path> [name] [--firewall]" >&2; exit 1; }

# --- Resolve the repo to a local path -------------------------------------------------
if [ -d "$INPUT" ]; then
	# Already a local directory - use it directly, no clone.
	REPO_PATH="$(cd "$INPUT" && pwd)"
	echo "Using existing local repo: $REPO_PATH"
else
	# Treat as a URL or owner/repo shorthand; normalize to a clone URL.
	case "$INPUT" in
		git@*:*) URL="$INPUT" ;;
		http://*|https://*) URL="$INPUT" ;;
		*/*) URL="https://github.com/$INPUT" ;;   # owner/repo shorthand
		*) echo "Error: '$INPUT' is not a URL, owner/repo, or existing directory." >&2; exit 1 ;;
	esac
	base="${URL%.git}"; base="${base%/}"; base="${base##*/}"   # repo name from the URL
	dirname="${NAME:-$base}"
	REPO_PATH="$CODE_DIR/$dirname"
	if [ -d "$REPO_PATH/.git" ]; then
		echo "Repo already cloned at $REPO_PATH - reusing it."
	else
		echo "Cloning $URL -> $REPO_PATH ..."
		mkdir -p "$CODE_DIR"
		if ! git clone "$URL" "$REPO_PATH"; then
			cat >&2 <<EOF

Clone failed. If this is a private repo and git asked for credentials, wire up your
GitHub login once (see SETUP.md), e.g. with the Windows GitHub CLI:

  git config --global credential."https://github.com".helper \\
    '!"/mnt/c/Program Files/GitHub CLI/gh.exe" auth git-credential'

then re-run this command.
EOF
			exit 1
		fi
	fi
fi

# --- Create the environment -----------------------------------------------------------
echo
NEWENV_ARGS=(--repo "$REPO_PATH" "${FIREWALL[@]}")
[ -n "$NAME" ] && NEWENV_ARGS+=(--name "$NAME")
out="$("$REPO_ROOT/scripts/new-env.sh" "${NEWENV_ARGS[@]}")"
printf '%s\n' "$out"

# Pull the env name + port back out of new-env.sh's output.
ENV_NAME="$(printf '%s\n' "$out" | sed -n "s/^Environment '\(.*\)' is up.*/\1/p" | head -1)"
PORT="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*SSH Port[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
[ -n "$ENV_NAME" ] || { echo "Error: could not determine the environment name from new-env.sh output." >&2; exit 1; }

# --- Enable git inside the container (best effort) ------------------------------------
echo
if "$REPO_ROOT/scripts/setup-git-auth.sh" "$ENV_NAME"; then
	GIT_OK=1
else
	GIT_OK=0
	echo "WARNING: git auth could not be set up automatically." >&2
	echo "  Run it yourself later:  scripts/setup-git-auth.sh $ENV_NAME" >&2
fi

# --- Final summary --------------------------------------------------------------------
IDLINE="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Identity File[[:space:]]*:[[:space:]]*//p' | head -1)"
cat <<EOF

============================================================
 DONE - '$ENV_NAME' is ready.
============================================================
 Add this SSH environment in the Claude desktop app:

   SSH Host      : node@127.0.0.1
   SSH Port      : ${PORT:-<see above>}
   Identity File : ${IDLINE:-your Windows %USERPROFILE%\\.ssh\\id_ed25519}
   Folder        : /workspaces/$ENV_NAME

 First connection only - accept the fingerprint from PowerShell:
   ssh -p ${PORT:-<port>} node@127.0.0.1     (type 'yes'; no password)

 Git inside the container: $([ "$GIT_OK" = "1" ] && echo "enabled" || echo "NOT set up - see warning above")
 Recreate later (keeps history): scripts/rebuild.sh $ENV_NAME
============================================================
EOF
