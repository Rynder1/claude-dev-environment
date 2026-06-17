#!/usr/bin/env bash
# Pre-flight checks for the claude-dev-environment host (run inside WSL).
# Catches the common first-run failures before you build images or spin up containers.
# Does not change anything. Exits non-zero if any hard check FAILs.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_TAG="claude-dev:latest"
CHECK_FIREWALL=0
REPO_PATH=""

usage() {
	cat <<'EOF'
Usage: doctor.sh [--repo <path>] [--firewall] [--image <tag>]

  --repo <path>  Also check a candidate repo mount path (exists? on a fast filesystem?).
  --firewall     Also test the egress-firewall prerequisites in a throwaway container
                 (needs the base image built; verifies iptables + ipset + NET_ADMIN).
  --image <tag>  Base image tag to look for (default: claude-dev:latest).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo) REPO_PATH="${2:-}"; shift 2;;
		--firewall) CHECK_FIREWALL=1; shift;;
		--image) IMAGE_TAG="${2:-}"; shift 2;;
		-h|--help) usage; exit 0;;
		*) echo "Unknown argument: $1" >&2; usage; exit 1;;
	esac
done

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== claude-dev-environment doctor =="

# 1. Running inside WSL?
if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
	ok "running inside WSL"
else
	warn "not detected as WSL - Docker host networking / localhost forwarding may differ"
fi

# 2. Docker binary present?
HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1; then
	ok "docker present: $(docker --version 2>/dev/null)"
	HAVE_DOCKER=1
else
	fail "docker not installed - run scripts/setup-wsl.sh"
fi

# 3. Docker daemon reachable without sudo?
if [ "$HAVE_DOCKER" = "1" ]; then
	if docker info >/dev/null 2>&1; then
		ok "docker daemon reachable without sudo"
	else
		fail "docker daemon not reachable without sudo - start it ('sudo service docker start' or 'sudo systemctl start docker') and add yourself to the docker group ('sudo usermod -aG docker \$USER' then open a NEW shell)"
	fi

	# 4. Compose v2?
	if docker compose version >/dev/null 2>&1; then
		ok "docker compose v2 available"
	else
		fail "docker compose v2 not available - install the docker-compose-plugin"
	fi
fi

# 5. SSH key pair present (for the desktop app to connect)?
if ls "$HOME"/.ssh/id_ed25519.pub >/dev/null 2>&1 || ls "$HOME"/.ssh/id_rsa.pub >/dev/null 2>&1; then
	ok "SSH public key present in ~/.ssh"
else
	warn "no SSH public key in ~/.ssh - run scripts/setup-wsl.sh or 'ssh-keygen -t ed25519'"
fi

# 6. Base image built?
IMAGE_BUILT=0
if [ "$HAVE_DOCKER" = "1" ] && docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
	ok "base image '$IMAGE_TAG' is built"
	IMAGE_BUILT=1
else
	warn "base image '$IMAGE_TAG' not built yet - run scripts/build.sh"
fi

# 7. Candidate repo path (optional)
if [ -n "$REPO_PATH" ]; then
	if [ -d "$REPO_PATH" ]; then
		ok "repo path exists: $REPO_PATH"
		case "$REPO_PATH" in
			/mnt/*) warn "repo is on a Windows drive ($REPO_PATH) - bind mounts over /mnt are slow and have uid quirks; clone it into the WSL filesystem (e.g. ~/code) for speed" ;;
			*) ok "repo is on the WSL native filesystem (fast bind mounts)" ;;
		esac
	else
		fail "repo path not found: $REPO_PATH"
	fi
fi

# 8. Firewall prerequisites (optional, needs the image)
if [ "$CHECK_FIREWALL" = "1" ]; then
	if [ "$IMAGE_BUILT" = "1" ]; then
		if docker run --rm --cap-add=NET_ADMIN --entrypoint sh "$IMAGE_TAG" -c \
			'iptables -L >/dev/null 2>&1 && ipset create _doctor_test hash:net >/dev/null 2>&1 && ipset destroy _doctor_test >/dev/null 2>&1'; then
			ok "firewall prerequisites work (iptables + ipset under NET_ADMIN)"
		else
			fail "firewall test failed - the WSL2 kernel may lack the ip_set/iptables modules; the --firewall profile will not work until that is resolved"
		fi
	else
		warn "skipping firewall test - base image not built (run scripts/build.sh first)"
	fi
fi

echo
echo "== Summary: $PASS passed, $WARN warning(s), $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
	echo "Resolve the FAIL items above before running new-env.sh."
	exit 1
fi
echo "Ready. Next: scripts/build.sh (if needed), then scripts/add-repo.sh <url|owner/repo>."
exit 0
