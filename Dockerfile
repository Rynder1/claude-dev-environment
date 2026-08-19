FROM mcr.microsoft.com/devcontainers/javascript-node:20

USER root

ARG CLAUDE_PACKAGE=@anthropic-ai/claude-code

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		openssh-server git ca-certificates \
		iptables ipset dnsutils \
		ruby-full \
	&& rm -rf /var/lib/apt/lists/* \
	&& mkdir -p /var/run/sshd \
	&& ssh-keygen -A

# GitHub CLI (gh) - not in the default Debian repos, so add GitHub's apt source.
RUN install -m 0755 -d /etc/apt/keyrings \
	&& curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
		-o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
		> /etc/apt/sources.list.d/github-cli.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends gh \
	&& rm -rf /var/lib/apt/lists/*

# Bundler isn't part of ruby-full; install it system-wide so `bundle` is on PATH
# for every user out of the box (per-project gems still install to the node user's
# writable GEM_HOME - see config/profile.d/ruby-env.sh).
RUN gem install --no-document bundler

RUN npm install -g ${CLAUDE_PACKAGE}

COPY config/sshd/claude.conf /etc/ssh/sshd_config.d/claude.conf
COPY config/claude/settings.default.json /opt/claude-defaults/settings.json
# Login-shell drop-ins: auto-auth gh from the volume-persisted token, and put the
# node user's writable gem bin dir on PATH. Sourced by every login shell.
COPY config/profile.d/gh-token.sh /etc/profile.d/gh-token.sh
COPY config/profile.d/ruby-env.sh /etc/profile.d/ruby-env.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
