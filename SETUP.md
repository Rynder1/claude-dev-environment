# Setup guide — copy/paste, top to bottom

This sets up **one isolated Linux container per repo**, each driven from the **Claude Code
desktop app** over SSH. Containers are disposable; your Claude sessions, login, and git
credentials live on a volume that survives rebuilds.

Do **Part 1** once per computer. Do **Part 2 + 3** once per repo. That's it.

> **Mental model:** nothing secret is ever stored in this git repo. Keys, tokens, the built
> image, and your sessions are all created locally on your machine. Sharing = sharing this
> repo; everyone wires up their own keys and tokens.

---

## Before you start

You need, on Windows:
- **WSL2** with an Ubuntu distro (`wsl --install` if you don't have it).
- The **Claude Code desktop app**.
- A **GitHub login** with access to the repos you want to work on.

Run every command below **inside WSL** (open "Ubuntu" from the Start menu), unless it says
PowerShell.

---

## Part 1 — set up the machine (once)

### 1.1  Check the SSH bridge works
*What & why: the desktop app shells out to Windows' `ssh.exe`. A known Windows bug can break
this. Confirm it works before building anything.*

```bash
sudo apt-get update && sudo apt-get install -y openssh-server
sudo service ssh start
```
Then in the **desktop app**, add an SSH connection to `you@127.0.0.1` (port 22) with your key
and confirm it connects. If it errors with `spawn ssh ENOENT`, fix that first (make sure
`ssh.exe` is on your Windows PATH). If it connects, you're good — remove that test connection.

### 1.2  Get this repo
*What & why: this repo holds the scripts and config. It carries no secrets.*

```bash
git clone https://github.com/Rynder1/claude-dev-environment ~/claude-dev-environment
cd ~/claude-dev-environment
```

### 1.3  Install Docker + make an SSH key
*What & why: installs Docker Engine inside WSL (no Docker Desktop needed) and generates the
WSL SSH key. After it runs, open a NEW shell so your `docker` group membership takes effect.*

```bash
scripts/setup-wsl.sh
# ...then close and reopen the Ubuntu terminal, cd back in, and verify:
docker run --rm hello-world
```

### 1.4  Pre-flight + build the image
*What & why: `doctor` catches common problems; `build` creates the one shared base image
(`claude-dev:latest`) that every container is started from.*

```bash
cd ~/claude-dev-environment
scripts/doctor.sh          # fix anything marked [FAIL] before continuing
scripts/build.sh
```

---

## Part 2 — add a repo (once per repo)

### The easy way: one command

*What & why: `add-repo.sh` does all of Part 2 for you — clone, create the container, enable
git — then prints exactly what to paste into the app. Pass a URL, an `owner/repo`, or a local
path (and optionally a name).*

```bash
scripts/add-repo.sh https://github.com/WiseTechGlobal/WTA.Ramen
# or:  scripts/add-repo.sh WiseTechGlobal/WTA.Ramen
# or:  scripts/add-repo.sh WiseTechGlobal/WTA.Ramen ramen     # custom name
```

When it finishes, jump to **Part 3** with the values it printed. (If the repo is private and
the clone asks for a password, do the git-credential one-liner in Troubleshooting once, then
re-run.) Prefer to understand each step? Do them manually below instead.

### The manual way

### 2.1  Clone the repo into WSL
*What & why: keep the code on the fast Linux filesystem (`~/code`), not `/mnt/c`. If git asks
for a password and you have the Windows GitHub CLI, run the one-liner in Troubleshooting first.*

```bash
git clone https://github.com/WiseTechGlobal/WTA.Ramen ~/code/WTA.Ramen
```

### 2.2  Create the environment
*What & why: builds a container for this repo, picks a free SSH port, and **authorizes both
your WSL and Windows SSH keys automatically** so the desktop app can connect.*

```bash
scripts/new-env.sh --repo ~/code/WTA.Ramen
```
Note the **port** and **folder** it prints (e.g. port `2201`, folder `/workspaces/SSH-WTA-Ramen`).

### 2.3  Turn on git inside the container
*What & why: lets Claude run git in the container. It stores a GitHub token on the container's
private volume (never in git, mode 600) and sets your commit name/email. Uses your GitHub CLI
login by default.*

```bash
scripts/setup-git-auth.sh SSH-WTA-Ramen
```

---

## Part 3 — connect from the desktop app (once per repo)

### 3.1  Accept the host key (first time only)
*What & why: the first SSH connection must confirm the server fingerprint. Doing it once in
PowerShell saves the app from failing with "verification failed".*

In **PowerShell** (use the port from step 2.2):
```powershell
ssh -p 2201 node@127.0.0.1
```
Type **`yes`** when asked. You should land on a prompt like `node@ssh-wta-ramen` with **no
password**. Type `exit`.

> Saw a **password prompt**? You used the wrong port (no `-p`), so you hit your WSL box, not the
> container. The containers are key-only and never ask for a password.

### 3.2  Add the connection in the app
In the desktop app, add an SSH environment:

| Field | Value |
|---|---|
| SSH Host | `node@127.0.0.1` |
| SSH Port | the port from step 2.2 (e.g. `2201`) |
| Identity File | your **Windows** key: `C:\Users\<you>\.ssh\id_ed25519` |
| Folder | `/workspaces/SSH-<RepoName>` (e.g. `/workspaces/SSH-WTA-Ramen`) |

Start a session in that folder. Done.

---

## Daily use

- **See everything:** `scripts/list-envs.sh` (names, ports, mounted repos).
- **Rebuild a broken container, keep history:** `scripts/rebuild.sh SSH-WTA-Ramen`.
- **Git safety:** read-only/staging git (`status`, `diff`, `add`, `rm`, `fetch`) runs freely;
  **commit and push always ask for your approval**; force-push / hard-reset are blocked.

---

## Troubleshooting

**Git asks for a username/password when cloning (step 2.1), or git fails inside the container.**
If you use the Windows GitHub CLI, wire it into WSL git once:
```bash
git config --global credential."https://github.com".helper \
  '!"/mnt/c/Program Files/GitHub CLI/gh.exe" auth git-credential'
```
No GitHub CLI? Create a Personal Access Token on GitHub and feed it in:
```bash
echo "<your-token>" | scripts/setup-git-auth.sh SSH-WTA-Ramen --stdin
```

**Desktop app says "verification failed".** Make sure the **SSH Port** field is the container
port (e.g. `2201`), not `22`, and that you accepted the fingerprint in step 3.1.

**The app can't authenticate / asks for a password.** It's using a Windows key the container
doesn't know. Re-authorize it explicitly:
```bash
scripts/new-env.sh --repo ~/code/WTA.Ramen --win-key /mnt/c/Users/<you>/.ssh/id_ed25519.pub
```

---

## What's persistent vs disposable

| On the `claude-<name>` volume (survives rebuild) | In the container (thrown away on rebuild) |
|---|---|
| Claude sessions / transcripts | the OS, apt packages, Claude Code binary |
| Login token, `settings.json` (guardrails) | anything installed ad-hoc |
| Git credentials + `~/.gitconfig` | |

Your repo is bind-mounted from `~/code`, so it's never inside the container's disposable layer
either. See `README.md` for the full design and the optional egress firewall.
