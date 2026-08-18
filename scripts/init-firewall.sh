#!/usr/bin/env bash
# Egress allowlist firewall for the locked-down (unattended) profile.
# Default-deny outbound; only DNS, loopback, established connections, inbound SSH,
# and a small allowlist of resolved domains are permitted. Requires NET_ADMIN.
# Modeled on the Anthropic dev container init-firewall pattern.
set -euo pipefail

echo "init-firewall: applying egress allowlist..."

iptables -F
iptables -X || true
# NOTE: do NOT flush the nat table. Docker installs a DNAT rule there that redirects the
# container's embedded DNS resolver (127.0.0.11:53) to dockerd's DNS server. Flushing nat
# breaks name resolution entirely - dig returns nothing, the allowlist ipset ends up empty,
# and every allowlisted domain becomes unreachable. Leave nat intact.
iptables -t mangle -F || true

ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Inbound SSH so the desktop app can still connect once egress is locked.
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# DNS egress only to the resolver(s) this container actually uses (from /etc/resolv.conf),
# not the whole internet - that would be a DNS-tunnelling exfil path. Docker's embedded
# resolver (127.0.0.11) is loopback and already covered by the lo ACCEPT rule above; DNS
# responses come back via the ESTABLISHED rule, so no broad inbound sport-53 rule is needed.
for _ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null); do
	case "$_ns" in 127.*) continue;; esac
	printf '%s' "$_ns" | grep -qE '^[0-9]+(\.[0-9]+){3}$' || continue
	iptables -A OUTPUT -p udp -d "$_ns" --dport 53 -j ACCEPT
	iptables -A OUTPUT -p tcp -d "$_ns" --dport 53 -j ACCEPT
done

# Fail closed from here on: the loopback / established / inbound-SSH rules are in place, so
# if anything below errors out (e.g. resolving the allowlist) we drop to default-deny instead
# of leaving egress wide open. SSH stays reachable for debugging.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then \
	echo "init-firewall: FAILED (rc=$rc) - failing closed (egress denied)" >&2; \
	iptables -P INPUT DROP 2>/dev/null || true; \
	iptables -P OUTPUT DROP 2>/dev/null || true; \
	iptables -P FORWARD DROP 2>/dev/null || true; fi' EXIT

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
