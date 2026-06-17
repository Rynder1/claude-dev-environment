FROM mcr.microsoft.com/devcontainers/javascript-node:20

USER root

ARG CLAUDE_PACKAGE=@anthropic-ai/claude-code

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		openssh-server git ca-certificates \
		iptables ipset dnsutils \
	&& rm -rf /var/lib/apt/lists/* \
	&& mkdir -p /var/run/sshd \
	&& ssh-keygen -A

RUN npm install -g ${CLAUDE_PACKAGE}

COPY config/sshd/claude.conf /etc/ssh/sshd_config.d/claude.conf
COPY config/claude/settings.default.json /opt/claude-defaults/settings.json
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
