#!/usr/bin/env bash
set -euo pipefail

echo "== Claude dev environment: WSL2 host setup =="

if ! grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
	echo "Warning: this does not look like a WSL distro. Continuing anyway." >&2
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "Installing Docker Engine (no Docker Desktop)..."
	# Download the installer to a file first (never pipe the network straight into sh): a
	# truncated download can't then execute half a script, and the file can be inspected or
	# checksum-verified before it runs. get.docker.com changes over time so it isn't pinned
	# by default - set DOCKER_INSTALL_SHA256 to require an exact match.
	inst="$(mktemp /tmp/get-docker.XXXXXX.sh)"
	curl -fsSL https://get.docker.com -o "$inst"
	if [ -n "${DOCKER_INSTALL_SHA256:-}" ]; then
		echo "${DOCKER_INSTALL_SHA256}  ${inst}" | sha256sum -c - \
			|| { echo "Error: get.docker.com checksum mismatch - aborting." >&2; rm -f "$inst"; exit 1; }
	else
		echo "  (installer saved at $inst; review it, or set DOCKER_INSTALL_SHA256 to enforce a checksum)"
	fi
	sh "$inst"
	rm -f "$inst"
else
	echo "Docker already installed: $(docker --version)"
fi

if ! getent group docker >/dev/null 2>&1; then
	sudo groupadd docker || true
fi
sudo usermod -aG docker "$USER" || true

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^docker'; then
	sudo systemctl enable --now docker || true
else
	echo "systemd not active; starting docker via service manager..."
	sudo service docker start || true
fi

if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
	echo "Generating an ed25519 SSH key pair (no passphrase) for the desktop app to use..."
	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi

echo
echo "Done."
echo "  - Open a NEW shell so 'docker' group membership applies."
echo "  - Verify with: docker run --rm hello-world"
echo "  - Then build the base image: scripts/build.sh"
