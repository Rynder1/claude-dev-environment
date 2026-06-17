#!/usr/bin/env bash
# Show every claude-dev environment at a glance: status, SSH port, firewall, mounted repo.
# Read-only.
set -uo pipefail

if ! command -v docker >/dev/null 2>&1; then
	echo "docker not found - run scripts/setup-wsl.sh first." >&2
	exit 1
fi

mapfile -t CONTAINERS < <(docker ps -a --filter "name=claude-" --format '{{.Names}}' | sort)

if [ "${#CONTAINERS[@]}" -eq 0 ]; then
	echo "No claude-dev environments found."
	echo "Create one with: scripts/new-env.sh --repo <path>"
	exit 0
fi

printf '%-22s %-10s %-7s %-9s %s\n' "NAME" "STATUS" "PORT" "FIREWALL" "REPO (host path -> /workspaces/<name>)"
printf '%-22s %-10s %-7s %-9s %s\n' "----" "------" "----" "--------" "--------------------------------------"

for c in "${CONTAINERS[@]}"; do
	status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo '?')"

	port="$(docker port "$c" 22/tcp 2>/dev/null | head -1 | sed 's/.*://')"
	[ -n "$port" ] || port="-"

	repo="$(docker inspect -f '{{range .Mounts}}{{.Destination}}={{.Source}}{{"\n"}}{{end}}' "$c" 2>/dev/null \
		| grep '^/workspaces/' | head -1 | cut -d= -f2-)"
	[ -n "$repo" ] || repo="-"

	fw="off"
	if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null \
		| grep -q '^ENABLE_FIREWALL=1'; then
		fw="on"
	fi

	printf '%-22s %-10s %-7s %-9s %s\n' "$c" "$status" "$port" "$fw" "$repo"
done

echo
echo "Connect in the desktop app: SSH node@127.0.0.1, port <PORT>, folder /workspaces/<name>."
echo "Recreate one (keeps history): scripts/rebuild.sh <name>"
