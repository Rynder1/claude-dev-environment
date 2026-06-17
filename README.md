# claude-dev-environment

Reusable infrastructure for running **one isolated Linux container per repo**, each driven
from the **Claude Code desktop app** over SSH. No Docker Desktop required — Docker Engine
runs inside a WSL2 distro.

The point: containers are disposable, your Claude **sessions and login are not**. Each repo's
`~/.claude` (transcripts + auth + config) lives on a named volume that survives container
recreation, so you can blow away and rebuild a broken environment and lose nothing.

> **Just want to get set up?** Follow **[SETUP.md](SETUP.md)** — a copy/paste, top-to-bottom
> guide (machine setup once, then per-repo). This README is the design reference behind it.

## How it fits together

```
Windows  ─ Claude desktop app
              │  (SSH environment, one connection per repo)
              ▼
WSL2 Ubuntu ─ Docker Engine
              ├─ container claude-alpha   :2200  →  repo alpha   + volume claude-alpha
              ├─ container claude-beta    :2201  →  repo beta    + volume claude-beta
              └─ ...
```

Each container runs `sshd` + Claude Code. The desktop app connects to `node@127.0.0.1:<port>`,
runs the session inside the container, and shows it as its own tab. You keep the
tab-per-repo / resume / "waiting on me" view; execution, auth, and history are isolated per repo.

## Prerequisites

- Windows 11 with WSL2 and an Ubuntu distro.
- The Claude desktop app on Windows.
- **WSL2 localhost forwarding** (on by default) so a port inside WSL is reachable at
  `127.0.0.1:<port>` on Windows.

## STEP 0 — validate the desktop-app SSH bridge first

Everything here depends on the desktop app being able to open an SSH connection on Windows.
There have been reports of a Windows bug (`spawn /usr/bin/ssh ENOENT`). Confirm it works
**before** building containers:

1. In WSL: `sudo apt-get install -y openssh-server && sudo service ssh start`
2. In the desktop app, add an SSH connection to `you@127.0.0.1` (port 22) with your key.
3. If it connects → proceed. If it throws `ENOENT`, fix that first (ensure `ssh.exe` is on
   PATH / apply the documented workaround); there is no point building on a broken bridge.

## STEP 1 — one-time WSL host setup

From the repo root, inside WSL:

```bash
scripts/setup-wsl.sh
```

Installs Docker Engine (via `get.docker.com`), adds you to the `docker` group, starts the
daemon, and generates an SSH key pair if you don't have one. Open a new shell afterwards and
verify: `docker run --rm hello-world`.

## STEP 1.5 — pre-flight check (optional but recommended)

Before building, run the doctor to catch the common first-run failures (no Docker daemon,
missing docker group, no SSH key, slow `/mnt` repo path, missing firewall kernel modules):

```bash
scripts/doctor.sh                                   # host checks
scripts/doctor.sh --repo ~/code/alpha               # also vet a repo you plan to mount
scripts/doctor.sh --firewall                         # also test the egress-firewall prereqs (needs the image)
```

It changes nothing and exits non-zero if a hard check fails.

## STEP 2 — build the base image (once)

```bash
scripts/build.sh                # tags claude-dev:latest
```

Rebuild only when you change the `Dockerfile` (new tools, newer Claude Code). Pin a version
if you prefer: `scripts/build.sh claude-dev:1.0`.

## STEP 3 — spin up an environment per repo

**Fastest path — one command from a URL:**

```bash
scripts/add-repo.sh https://github.com/you/alpha     # clone + env + git auth + print app values
scripts/add-repo.sh you/alpha alpha                  # owner/repo shorthand + custom name
```

`add-repo.sh` clones the repo into `~/code` (or uses a local path), creates the env, enables
git inside it, and prints the exact desktop-app values. The lower-level steps below are what it
runs for you:

```bash
scripts/new-env.sh --repo /home/you/code/alpha
scripts/new-env.sh --repo /home/you/code/beta --port 2201
```

`new-env.sh` picks the next free port (from 2200), authorizes your SSH keys, generates
`envs/<name>.compose.yml`, and starts the container. It prints the exact SSH details to paste
into the desktop app. Environments are named `SSH-<RepoName>` so they sort together and don't
collide with your local (non-SSH) projects.

By default it authorizes **both** your WSL key (for `ssh` from inside WSL) and your **Windows**
key (auto-detected from your Windows user profile — this is the key the desktop app actually
connects with), so the connection just works.

Flags: `--name`, `--port`, `--pubkey <file>`, `--win-key <file>`, `--image <tag>`,
`--firewall` (egress lockdown — see Safety).

### Enable git inside the container

```bash
scripts/setup-git-auth.sh SSH-<name>
```

Stores a GitHub token in the env's volume credential store (mode 600, never in the image or
git), points git at it, and sets your commit identity. By default it pulls the token from your
GitHub CLI login; use `--token-cmd`/`--stdin` for a Personal Access Token, and `--name`/`--email`
to override the commit identity. Because the credential lives on the volume and `~/.gitconfig`
is symlinked there, git auth survives `rebuild.sh`.

## STEP 4 — connect from the desktop app

For each environment, add an SSH connection using the details `new-env.sh` printed:

- **SSH Host**: `node@127.0.0.1`
- **SSH Port**: the port shown (e.g. `2200`)
- **Identity File**: your **Windows** private key, e.g. `C:\Users\<you>\.ssh\id_ed25519`
  (the desktop app uses Windows `ssh.exe` — `new-env.sh` prints the exact path)

First time only, accept the host fingerprint from PowerShell: `ssh -p <port> node@127.0.0.1`
(type `yes`; you should log in with no password). A password prompt means you used the wrong
port — the containers are key-only.

The repo is mounted at `/workspaces/SSH-<name>` inside the container. Start/resume sessions there.

## See what's running

```bash
scripts/list-envs.sh
```

Lists every environment with its status, SSH port, firewall state, and mounted repo — handy
for remembering which port maps to which repo when adding connections in the desktop app.

## Recreate without losing anything

```bash
scripts/rebuild.sh alpha            # force-recreate the container
scripts/rebuild.sh alpha --image    # also rebuild the base image first
```

The container is replaced; the `claude-<name>` volume (which holds `/home/node/.claude` —
all transcripts, login, settings) is preserved. Reconnect in the desktop app and `--resume`
shows full history. Other environments are untouched.

## What's persistent vs disposable

| Lives in the **volume** `claude-<name>` (persistent) | Lives in the **container** (disposable) |
|---|---|
| `~/.claude/projects/*/*.jsonl` session transcripts | OS, apt packages, Claude Code binary |
| Login / auth token, `settings.json`, MCP config | anything you installed ad-hoc |

Your repo itself is bind-mounted from the WSL filesystem, so it is never inside the container's
disposable layer either.

## Safety — permission mode (auto mode + guardrails)

These containers run Claude Code in **auto mode**, not `--dangerously-skip-permissions`. Auto
mode routes each action through a separate **safety classifier** that auto-approves routine work
but blocks anything dangerous or irreversible
([docs](https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode)).
Blocked by default include: `curl | bash`, exfiltrating data to external endpoints, production
deploys/migrations, mass cloud deletion, granting IAM/repo permissions, **destroying files that
existed before the session**, and **force push / pushing to `main`**.

On top of the classifier we seed deterministic guardrails (rules survive context compaction; a
stated "don't push" boundary does not). `config/claude/settings.default.json` is copied into each
volume's `~/.claude/settings.json` **on first run only** (your later edits are never clobbered):

```json
{
  "permissions": {
    "defaultMode": "auto",
    "ask": ["Bash(git push:*)"]
  },
  "autoMode": {
    "environment": ["$defaults"],
    "soft_deny":   ["$defaults"],
    "hard_deny":   ["$defaults", "Never send repository contents, secrets, or environment variables to external APIs/domains not in the trusted environment list"]
  }
}
```

- `ask` on `git push:*` → **every push stops for confirmation** (belt-and-braces over the
  classifier's force-push/main block). Narrow it later if you want routine pushes to flow.
- **Keep `"$defaults"` in every `autoMode` array.** Omitting it *replaces* the built-in rule list
  (force-push, `curl | bash`, exfiltration protections all vanish). Inspect effective rules with
  `claude auto-mode config`.
- `defaultMode: "auto"` only takes effect from **user settings** (`~/.claude/settings.json`) — it is
  ignored in project `.claude/settings.json`. That is exactly where we seed it (the volume).
- Requirements: a supported model (Opus 4.6+/Sonnet 4.6+) and, on Team/Enterprise, admin enablement.
  If unmet, the setting silently falls back to `default` (more prompts, never less safety).
- For absolute, non-negotiable blocks use `permissions.deny` — it runs before the classifier and
  cannot be overridden.

## Optional egress lockdown (`--firewall`)

Default egress is **open** so the agent can research freely. For unattended runs, add a default-deny
outbound firewall (allowlist only) as a second layer under the classifier:

```bash
scripts/new-env.sh --repo /home/you/code/alpha --firewall
```

This adds `cap_add: NET_ADMIN` and runs `init-firewall.sh` at container start (Anthropic
init-firewall pattern). The allowlist covers Anthropic/Claude, npm, and GitHub; extend it by
setting `FIREWALL_EXTRA_DOMAINS` in the generated `envs/<name>.firewall.yml`. `rebuild.sh`
auto-detects the overlay, so the lockdown survives recreation. Without `--firewall`, egress is open.

## Layout

```
Dockerfile                          base image: node 20 + sshd + Claude Code + iptables/ipset
config/sshd/claude.conf             hardened sshd settings (pubkey only, user 'node')
config/claude/settings.default.json seeded auto-mode + guardrails (copied to the volume on 1st run)
config/docker-compose.firewall.template.yml  --firewall overlay (NET_ADMIN + ENABLE_FIREWALL)
docker-compose.template.yml         per-env template (rendered into envs/)
scripts/
  setup-wsl.sh               one-time: install Docker Engine in WSL, make an SSH key
  doctor.sh                  pre-flight checks (docker, group, ssh key, repo path, firewall)
  build.sh                   build/tag the base image
  add-repo.sh                one-shot: clone a URL + create env + git auth + print app values
  new-env.sh                 stamp out + start a container for a repo (authorizes WSL + Windows keys)
  setup-git-auth.sh          provision git creds + identity into a container's volume (token via gh/PAT)
  list-envs.sh               show all environments: status, SSH port, firewall, mounted repo
  rebuild.sh                 force-recreate one container, keep its volume (+ firewall overlay)
  entrypoint.sh              seeds settings, installs authorized_keys, runs firewall, runs sshd
  init-firewall.sh           egress allowlist (runs only when ENABLE_FIREWALL=1)
envs/        (gitignored)    generated per-env compose + firewall overlay files
secrets/     (gitignored)    per-env authorized_keys
```

## Security notes

- **No secrets in git.** `secrets/` and `envs/` are gitignored. The image holds no keys; your
  public key is mounted read-only at runtime.
- Ports bind to `127.0.0.1` only — not exposed to the LAN.
- sshd is pubkey-only, root login disabled, restricted to user `node`.
- Host keys are generated at image build time, so they're shared across containers from the
  same image and stable across recreation (no `known_hosts` churn). For single-machine local
  dev this is an accepted trade-off; rebuild the image to rotate them.
