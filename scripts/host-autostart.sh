#!/usr/bin/env bash
# Run at Windows logon (Task Scheduler -> hidden VBS -> wsl.exe) so the WSL distro is awake
# and the persistent Claude containers are up before you open the desktop app - no need to
# open an Ubuntu terminal first. Safe to run repeatedly / by hand.
set -uo pipefail

echo "=== host-autostart: $(date '+%Y-%m-%d %H:%M:%S%z') ==="

# systemd starts dockerd on boot, but give the daemon a moment to come up.
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done

# Start every claude-dev container. `unless-stopped` already restarts ones that were running
# at shutdown; this also covers any that were manually stopped, and is a harmless no-op for
# ones already running.
ids="$(docker ps -aq --filter name=claude- 2>/dev/null || true)"
[ -n "$ids" ] && docker start $ids >/dev/null 2>&1 || true
echo "host-autostart: done ($(docker ps --filter name=claude- --format '{{.Names}}' | tr '\n' ' '))"
