#!/usr/bin/env bash
# Toggle the egress firewall for a RUNNING container, live, without recreating it.
#
#   scripts/firewall.sh <env-name> status   # show current state (default if omitted)
#   scripts/firewall.sh <env-name> off      # open egress now  (temporary)
#   scripts/firewall.sh <env-name> on       # re-apply the allowlist now
#
# 'off' flushes the in-container iptables rules, so egress opens immediately - no restart,
#       no lost work, your SSH session stays up. Use it when a task genuinely needs to reach
#       hosts outside the allowlist, then turn it back 'on'.
# 'on'  re-runs init-firewall.sh inside the container (re-resolves the allowlist, incl. any
#       FIREWALL_EXTRA_DOMAINS the env was created with).
#
# Safety notes:
#   * 'off' is always TEMPORARY. Because the env was created with --firewall, ENABLE_FIREWALL=1
#     persists in its compose file, so a plain `docker restart` (or a host reboot) re-locks the
#     firewall automatically. You cannot accidentally leave it open across a restart.
#   * The firewall is only the SECOND layer. Claude Code's auto-mode classifier still blocks
#     exfiltration of repo contents / secrets to untrusted domains even while egress is open.
#   * 'on' needs the NET_ADMIN capability, which is only present if the env was created with
#     --firewall. If it wasn't, recreate it with --firewall (see new-env.sh).
set -euo pipefail

ENV_NAME="${1:-}"
ACTION="${2:-status}"
[ -n "$ENV_NAME" ] || { echo "Usage: firewall.sh <env-name> [on|off|status]" >&2; exit 1; }

# Resolve the real container name (case-insensitive match on claude-<env>).
CONTAINER="$(docker ps --format '{{.Names}}' | grep -ix "claude-${ENV_NAME#claude-}" || true)"
[ -n "$CONTAINER" ] || {
	echo "Error: no running container matches 'claude-${ENV_NAME#claude-}'." >&2
	docker ps --filter "name=claude-" --format '  {{.Names}}' >&2
	exit 1
}

case "$ACTION" in
	status)
		docker exec -u root "$CONTAINER" bash -lc '
			pol="$(iptables -S OUTPUT 2>/dev/null | grep -m1 "^-P OUTPUT" || echo "?")"
			n="$(ipset list allowed-domains 2>/dev/null | grep -cE "^[0-9]" || echo 0)"
			enabled="${ENABLE_FIREWALL:-0}"
			if printf "%s" "$pol" | grep -q DROP; then
				echo "firewall: ON  (egress default-DROP, $n allowlisted IPs)"
			else
				echo "firewall: OFF (egress open)"
			fi
			echo "configured to lock on (re)start: $([ "$enabled" = "1" ] && echo yes || echo no)"
			[ -n "${FIREWALL_EXTRA_DOMAINS:-}" ] && echo "extra allowlist domains: $FIREWALL_EXTRA_DOMAINS"
		' || { echo "Error: could not read firewall state (is iptables present / NET_ADMIN granted?)." >&2; exit 1; }
		;;
	off)
		echo "Opening egress on $CONTAINER (temporary - a restart re-locks it)..."
		docker exec -u root "$CONTAINER" bash -lc '
			iptables -P INPUT  ACCEPT
			iptables -P FORWARD ACCEPT
			iptables -P OUTPUT ACCEPT
			iptables -F
			ipset destroy allowed-domains 2>/dev/null || true
		'
		echo "Egress is now OPEN. Turn it back on with: scripts/firewall.sh $ENV_NAME on"
		;;
	on)
		echo "Re-applying the egress allowlist on $CONTAINER..."
		docker exec -u root "$CONTAINER" /usr/local/bin/init-firewall.sh
		;;
	*)
		echo "Unknown action '$ACTION' (use: on | off | status)" >&2; exit 1 ;;
esac
