#!/usr/bin/env bash
# Egress allowlist firewall for the locked-down (unattended) profile.
# Default-deny outbound; only DNS, loopback, established connections, inbound SSH,
# and a small allowlist of resolved domains are permitted. Requires NET_ADMIN.
# Modeled on the Anthropic dev container init-firewall pattern.
set -euo pipefail

echo "init-firewall: applying egress allowlist..."

iptables -F
iptables -X || true
iptables -t nat -F || true
iptables -t mangle -F || true

ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Inbound SSH so the desktop app can still connect once egress is locked.
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

ALLOWED_DOMAINS=(
	"api.anthropic.com"
	"claude.ai"
	"console.anthropic.com"
	"statsig.anthropic.com"
	"sentry.io"
	"registry.npmjs.org"
	"github.com"
	"api.github.com"
	"codeload.github.com"
	"objects.githubusercontent.com"
	"raw.githubusercontent.com"
)

if [ -n "${FIREWALL_EXTRA_DOMAINS:-}" ]; then
	IFS=', ' read -r -a extra <<< "$FIREWALL_EXTRA_DOMAINS"
	ALLOWED_DOMAINS+=("${extra[@]}")
fi

for domain in "${ALLOWED_DOMAINS[@]}"; do
	[ -n "$domain" ] || continue
	ips="$(dig +short A "$domain" || true)"
	for ip in $ips; do
		if printf '%s' "$ip" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
			ipset add allowed-domains "$ip" 2>/dev/null || true
		fi
	done
done

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

echo "init-firewall: egress restricted to ${#ALLOWED_DOMAINS[@]} allowlisted domains."
