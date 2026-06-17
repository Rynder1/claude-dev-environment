#!/usr/bin/env bash
set -euo pipefail

SSH_USER="${SSH_USER:-node}"
USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"

mkdir -p "$USER_HOME/.ssh"
if [ -f /tmp/authorized_keys ]; then
	cp /tmp/authorized_keys "$USER_HOME/.ssh/authorized_keys"
else
	echo "WARNING: /tmp/authorized_keys not mounted - SSH key auth will fail." >&2
fi
chown -R "$SSH_USER":"$SSH_USER" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
[ -f "$USER_HOME/.ssh/authorized_keys" ] && chmod 600 "$USER_HOME/.ssh/authorized_keys"

mkdir -p "$USER_HOME/.claude"
# Seed default Claude settings (auto mode + guardrails) only on first run - never
# clobber the user's own settings that persist on the claude-<name> volume.
if [ ! -f "$USER_HOME/.claude/settings.json" ] && [ -f /opt/claude-defaults/settings.json ]; then
	cp /opt/claude-defaults/settings.json "$USER_HOME/.claude/settings.json"
fi
chown -R "$SSH_USER":"$SSH_USER" "$USER_HOME/.claude"

# Optional egress lockdown for unattended runs (opt-in via new-env.sh --firewall).
if [ "${ENABLE_FIREWALL:-0}" = "1" ]; then
	if ! /usr/local/bin/init-firewall.sh; then
		echo "WARNING: firewall init failed - egress is NOT locked down." >&2
	fi
fi

exec /usr/sbin/sshd -D -e
