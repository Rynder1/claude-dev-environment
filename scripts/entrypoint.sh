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

# Persist SSH host keys on the volume so the container's fingerprint stays STABLE
# across image rebuilds. Host keys are otherwise baked into the image (ssh-keygen -A
# at build time), so every image rebuild rotates them - and SSH clients then reject
# the connection ("REMOTE HOST IDENTIFICATION HAS CHANGED" / "verification failed"),
# forcing a manual re-accept. Storing them under ~/.claude means the fingerprint is
# established once and reused forever, no matter how often the image is rebuilt.
HOSTKEY_DIR="$USER_HOME/.claude/ssh-hostkeys"
mkdir -p "$HOSTKEY_DIR"
if compgen -G "$HOSTKEY_DIR/ssh_host_*_key" >/dev/null; then
	cp -a "$HOSTKEY_DIR"/ssh_host_* /etc/ssh/         # reuse the persisted keys
else
	cp -a /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "$HOSTKEY_DIR"/  # first run: adopt + persist
fi
chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true
chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

# Optional egress lockdown for unattended runs (opt-in via new-env.sh --firewall).
if [ "${ENABLE_FIREWALL:-0}" = "1" ]; then
	if ! /usr/local/bin/init-firewall.sh; then
		# init-firewall fails closed internally, but belt-and-braces: if it couldn't even run,
		# apply a minimal default-deny here so a broken firewall never leaves egress open.
		echo "WARNING: firewall init failed - applying emergency default-deny (fail-closed)." >&2
		iptables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
		iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
		iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
		iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
		iptables -A INPUT  -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
		iptables -P OUTPUT  DROP 2>/dev/null || true
		iptables -P INPUT   DROP 2>/dev/null || true
		iptables -P FORWARD DROP 2>/dev/null || true
	fi
	# Make the firewall changeable ONLY from the host. The node user (which Claude runs as)
	# ships with passwordless sudo, so without this it could `sudo iptables -F` and disable
	# its own egress firewall - defeating the point. Revoking node's sudo removes its path to
	# root/NET_ADMIN, so nothing inside the container can alter the rules; only `docker exec`
	# from the host (scripts/firewall.sh) can. Re-applied on every (re)start. To get a root
	# shell for maintenance, use the host:  docker exec -u root -it claude-<env> bash
	rm -f /etc/sudoers.d/node
	echo "entrypoint: firewall enabled - revoked in-container sudo (host-only control)."
fi

exec /usr/sbin/sshd -D -e
