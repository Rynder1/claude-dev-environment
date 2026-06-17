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

# Persist git's global config on the volume. ~/.gitconfig normally lives in the
# disposable container layer, so commit identity, the credential helper, and any
# user git config would be lost on every rebuild. Symlink it onto the claude-<name>
# volume (under ~/.claude) so all of it survives container recreation.
GITCONFIG_VOL="$USER_HOME/.claude/.gitconfig"
[ -f "$GITCONFIG_VOL" ] || : > "$GITCONFIG_VOL"
# Point git at the persistent credential store (idempotent). The token file itself,
# if any, is provisioned out-of-band and also lives on the volume - never in the image.
git config --file "$GITCONFIG_VOL" credential.helper "store --file=$USER_HOME/.claude/.git-credentials"
ln -sfn "$GITCONFIG_VOL" "$USER_HOME/.gitconfig"
chown "$SSH_USER":"$SSH_USER" "$GITCONFIG_VOL"
chown -h "$SSH_USER":"$SSH_USER" "$USER_HOME/.gitconfig"

# Optional egress lockdown for unattended runs (opt-in via new-env.sh --firewall).
if [ "${ENABLE_FIREWALL:-0}" = "1" ]; then
	if ! /usr/local/bin/init-firewall.sh; then
		echo "WARNING: firewall init failed - egress is NOT locked down." >&2
	fi
fi

exec /usr/sbin/sshd -D -e
