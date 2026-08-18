#!/usr/bin/env python3
"""
Local web dashboard for the claude-dev containers.

  python3 scripts/dashboard.py            # serve on http://127.0.0.1:8787
  python3 scripts/dashboard.py --port 9000 --interval 5 --open

It wraps `docker` and the repo's own scripts (firewall.sh, rebuild.sh), so it stays
consistent with the CLI. Features:
  * live table (auto-refresh, default 10s, changeable in the UI): status, SSH port,
    repo, uptime, firewall state + allowlist
  * per-container buttons: start / stop / restart / rebuild, firewall on / off,
    "root shell" (opens a Windows terminal already `docker exec -u root -it` in),
    and copy-SSH-details
Security: binds to 127.0.0.1 ONLY, validates the Host header (blocks DNS-rebinding),
and requires a per-run token for every /api call (printed at startup + embedded in the
page). It performs privileged actions (root shells, firewall toggles) so must never be
exposed off-machine.
"""
import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIREWALL_SH = os.path.join(REPO_ROOT, "scripts", "firewall.sh")
REBUILD_SH = os.path.join(REPO_ROOT, "scripts", "rebuild.sh")
DOCKER = shutil.which("docker") or "/usr/bin/docker"
CMDEXE = "/mnt/c/Windows/System32/cmd.exe"
TOKEN = secrets.token_urlsafe(24)
DISTRO = "Ubuntu"       # overridden by --distro
DEF_INTERVAL = 10


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except Exception as e:  # noqa
        return 1, "", str(e)


def docker(*args, timeout=30):
    return run([DOCKER, *args], timeout=timeout)


def gather():
    """Return a list of dicts describing every claude-* container."""
    rc, out, _ = docker("ps", "-a", "--filter", "name=claude-", "--format", "{{.Names}}")
    names = [n for n in out.split() if n]
    if not names:
        return []
    rc, out, _ = docker("inspect", *names)
    try:
        data = json.loads(out) if out.strip() else []
    except json.JSONDecodeError:
        data = []
    rows = []
    for d in data:
        name = d.get("Name", "").lstrip("/")            # claude-SSH-Charts
        env = re.sub(r"^claude-", "", name)             # SSH-Charts
        state = d.get("State", {}) or {}
        status = state.get("Status", "?")
        envmap = {}
        for e in (d.get("Config", {}) or {}).get("Env", []) or []:
            if "=" in e:
                k, v = e.split("=", 1)
                envmap[k] = v
        fw_enabled = envmap.get("ENABLE_FIREWALL", "0") == "1"
        extra_domains = envmap.get("FIREWALL_EXTRA_DOMAINS", "")
        port = ""
        p22 = ((d.get("NetworkSettings", {}) or {}).get("Ports", {}) or {}).get("22/tcp")
        if p22:
            port = p22[0].get("HostPort", "")
        repo, folder = "", f"/workspaces/{env}"
        for m in d.get("Mounts", []) or []:
            if str(m.get("Destination", "")).startswith("/workspaces/"):
                repo, folder = m.get("Source", ""), m.get("Destination", "")
                break
        fw_state, allow_ips = "n/a", None
        if fw_enabled and status == "running":
            rc2, o2, _ = docker(
                "exec", name, "sh", "-c",
                'iptables -S OUTPUT 2>/dev/null | grep -m1 "^-P OUTPUT"; echo "@@"; '
                'ipset list allowed-domains 2>/dev/null | grep -cE "^[0-9]"',
                timeout=15,
            )
            parts = o2.split("@@")
            pol = parts[0] if parts else ""
            if "DROP" in pol:
                fw_state = "on"
            elif "ACCEPT" in pol:
                fw_state = "off"
            if len(parts) > 1:
                try:
                    allow_ips = int(parts[1].strip())
                except ValueError:
                    allow_ips = None
        elif fw_enabled:
            fw_state = "stopped"
        rows.append(dict(
            name=name, env=env, status=status, restart=d.get("RestartCount", 0),
            started=state.get("StartedAt", ""), port=port, repo=repo, folder=folder,
            fw_enabled=fw_enabled, fw_state=fw_state, allow_ips=allow_ips,
            extra_domains=extra_domains,
        ))
    rows.sort(key=lambda r: r["env"].lower())
    return rows


def open_root_shell(container):
    inner = "exec docker exec -u root -it '%s' bash" % container
    args = [CMDEXE, "/c", "start", "", "wsl.exe", "-d", DISTRO, "-e", "bash", "-lc", inner]
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0, "Opening a root shell for %s in a new terminal window." % container, ""
    except Exception as e:  # noqa
        return 1, "", "could not launch terminal: %s" % e


def do_action(action, env):
    envname = re.sub(r"^claude-", "", env or "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", envname or ""):
        return 1, "", "invalid environment name"
    container = "claude-" + envname
    if action == "firewall_on":
        return run(["bash", FIREWALL_SH, envname, "on"])
    if action == "firewall_off":
        return run(["bash", FIREWALL_SH, envname, "off"])
    if action in ("start", "stop", "restart"):
        return docker(action, container, timeout=60)
    if action == "rebuild":
        return run(["bash", REBUILD_SH, envname], timeout=240)
    if action == "root_shell":
        return open_root_shell(container)
    return 1, "", "unknown action: %s" % action


PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>claude-dev control</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;font:14px/1.45 system-ui,Segoe UI,Roboto,sans-serif;background:#0f1216;color:#e7ebf0}
header{display:flex;align-items:center;gap:16px;flex-wrap:wrap;padding:14px 18px;background:#161b22;border-bottom:1px solid #2a313a;position:sticky;top:0}
h1{font-size:16px;margin:0;font-weight:650}
.spacer{flex:1}
.ctl{display:flex;align-items:center;gap:6px;color:#9aa7b4}
input[type=number]{width:56px;background:#0f1216;border:1px solid #2a313a;color:#e7ebf0;border-radius:6px;padding:4px 6px}
button{background:#22303f;color:#e7ebf0;border:1px solid #33465a;border-radius:6px;padding:5px 9px;cursor:pointer;font-size:12.5px}
button:hover{background:#2b3d50}
button:disabled{opacity:.35;cursor:default}
button.g{background:#12351f;border-color:#1f6b39}button.g:hover{background:#184a2a}
button.r{background:#3a1720;border-color:#6b2233}button.r:hover{background:#4d1e2b}
button.a{background:#3a3213;border-color:#6b5a1f}button.a:hover{background:#4d431a}
main{padding:16px 18px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:9px 10px;border-bottom:1px solid #222a33;vertical-align:top}
th{color:#8592a0;font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em}
tr:hover td{background:#131820}
.badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11.5px;font-weight:600;white-space:nowrap}
.b-run{background:#12351f;color:#5fd58a}.b-stop{background:#3a1720;color:#e98aa0}.b-other{background:#2a313a;color:#b8c2cc}
.b-on{background:#12351f;color:#5fd58a}.b-off{background:#3a3213;color:#e6c65b}.b-na{background:#2a313a;color:#8592a0}
.mono{font-family:ui-monospace,Consolas,monospace;font-size:12px;color:#b8c2cc}
.dim{color:#8592a0}
.acts{display:flex;flex-wrap:wrap;gap:5px}
.dom{color:#8592a0;font-size:11.5px}
#log{margin-top:14px;background:#0b0e12;border:1px solid #222a33;border-radius:8px;padding:10px 12px;font-family:ui-monospace,Consolas,monospace;font-size:12px;color:#b8c2cc;white-space:pre-wrap;max-height:180px;overflow:auto}
.err{color:#e98aa0}
.ok{color:#5fd58a}
a{color:#6cb6ff}
</style></head><body>
<header>
  <h1>claude-dev control</h1>
  <span class="badge b-na" id="conn">connecting…</span>
  <div class="spacer"></div>
  <label class="ctl"><input type="checkbox" id="auto" checked> auto</label>
  <label class="ctl">every <input type="number" id="ivl" min="2" max="600" value="__INTERVAL__"> s</label>
  <button onclick="refresh()">↻ refresh</button>
  <span class="ctl dim" id="stamp"></span>
</header>
<main>
  <table><thead><tr>
    <th>container</th><th>status</th><th>ssh port</th><th>firewall</th><th>repo</th><th>uptime</th><th>actions</th>
  </tr></thead><tbody id="rows"></tbody></table>
  <div id="log">ready.</div>
</main>
<script>
const TOKEN="__TOKEN__";
let timer=null;
function esc(s){return (s==null?"":String(s)).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));}
function ago(iso){ if(!iso||iso.startsWith("0001"))return "-"; const t=Date.parse(iso); if(isNaN(t))return "-";
  let s=Math.floor((Date.now()-t)/1000); if(s<0)s=0; const d=Math.floor(s/86400);s%=86400;const h=Math.floor(s/3600);s%=3600;const m=Math.floor(s/60);
  return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m`; }
function log(msg,cls){ const l=document.getElementById("log"); const ts=new Date().toLocaleTimeString();
  l.innerHTML=`<span class="dim">${ts}</span>  <span class="${cls||''}">${esc(msg)}</span>\n`+l.innerHTML; }
async function api(path,opts){ opts=opts||{}; opts.headers=Object.assign({"X-Token":TOKEN},opts.headers||{});
  const r=await fetch(path,opts); if(!r.ok) throw new Error(await r.text()); return r.json(); }
function fwCell(r){
  if(!r.fw_enabled) return '<span class="badge b-na">none</span>';
  if(r.fw_state==="on") return `<span class="badge b-on">ON</span> <span class="dim">${r.allow_ips!=null?r.allow_ips+" ips":""}</span>`+
     (r.extra_domains?`<div class="dom">+ ${esc(r.extra_domains)}</div>`:'');
  if(r.fw_state==="off") return '<span class="badge b-off">OFF</span> <span class="dim">(open)</span>';
  if(r.fw_state==="stopped") return '<span class="badge b-na">on@boot</span>';
  return '<span class="badge b-na">?</span>';
}
function actions(r){
  const run=r.status==="running"; let h='<div class="acts">';
  if(run){ h+=`<button class="r" onclick="act('stop','${r.env}')">stop</button>`;
           h+=`<button onclick="act('restart','${r.env}')">restart</button>`; }
  else   { h+=`<button class="g" onclick="act('start','${r.env}')">start</button>`; }
  if(r.fw_enabled && run){
    if(r.fw_state==="on")  h+=`<button class="a" onclick="act('firewall_off','${r.env}')">fw off</button>`;
    if(r.fw_state==="off") h+=`<button class="g" onclick="act('firewall_on','${r.env}')">fw on</button>`;
  }
  if(run) h+=`<button onclick="act('root_shell','${r.env}')">root shell</button>`;
  h+=`<button onclick="copySsh(${esc(JSON.stringify(JSON.stringify(r))).replace(/'/g,"&#39;")})">copy ssh</button>`;
  h+=`<button class="r" onclick="if(confirm('Rebuild ${r.env}? Container is recreated; volume/sessions kept.'))act('rebuild','${r.env}')">rebuild</button>`;
  return h+'</div>';
}
function copySsh(js){ let r; try{r=JSON.parse(js);}catch(e){return;}
  const s=`SSH Host: node@127.0.0.1\nSSH Port: ${r.port}\nFolder: ${r.folder}`;
  navigator.clipboard.writeText(s).then(()=>log("copied SSH details for "+r.env,"ok"),()=>log("clipboard blocked","err")); }
async function act(action,env){ try{ log(`${action} ${env}…`); const j=await api("/api/action",
    {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action,env})});
    log((j.output||"done").trim()+(j.error?("  "+j.error):""), j.rc===0?"ok":"err"); }
  catch(e){ log("action failed: "+e.message,"err"); } finally{ setTimeout(refresh,600); } }
async function refresh(){ try{ const rows=await api("/api/status");
    document.getElementById("conn").className="badge b-on"; document.getElementById("conn").textContent="live";
    const tb=document.getElementById("rows"); tb.innerHTML = rows.map(r=>{
      const sb = r.status==="running"?"b-run":(r.status==="exited"?"b-stop":"b-other");
      return `<tr><td><b>${esc(r.env)}</b><div class="dim mono">${esc(r.name)}</div></td>
        <td><span class="badge ${sb}">${esc(r.status)}</span>${r.restart?` <span class="dim">rc ${r.restart}</span>`:""}</td>
        <td class="mono">${esc(r.port||"-")}</td><td>${fwCell(r)}</td>
        <td class="mono">${esc(r.repo||"-")}<div class="dim">${esc(r.folder)}</div></td>
        <td>${ago(r.started)}</td><td>${actions(r)}</td></tr>`; }).join("")
      || '<tr><td colspan=7 class="dim">no claude-* containers found.</td></tr>';
    document.getElementById("stamp").textContent="updated "+new Date().toLocaleTimeString();
  }catch(e){ document.getElementById("conn").className="badge b-off"; document.getElementById("conn").textContent="error";
    log("refresh failed: "+e.message,"err"); } }
function schedule(){ if(timer)clearInterval(timer); if(document.getElementById("auto").checked){
    const s=Math.max(2,parseInt(document.getElementById("ivl").value||"10")); timer=setInterval(refresh,s*1000);} }
document.getElementById("auto").onchange=schedule;
document.getElementById("ivl").onchange=schedule;
refresh(); schedule();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _host_ok(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost")

    def _token_ok(self):
        return secrets.compare_digest(self.headers.get("X-Token", ""), TOKEN)

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, "bad host")
        if self.path == "/" or self.path.startswith("/?"):
            page = PAGE.replace("__TOKEN__", TOKEN).replace("__INTERVAL__", str(DEF_INTERVAL))
            return self._send(200, page, "text/html; charset=utf-8")
        if self.path == "/api/status":
            if not self._token_ok():
                return self._send(403, json.dumps({"error": "bad token"}))
            return self._send(200, json.dumps(gather()))
        return self._send(404, "not found")

    def do_POST(self):
        if not self._host_ok():
            return self._send(403, "bad host")
        if self.path != "/api/action":
            return self._send(404, json.dumps({"error": "not found"}))
        if not self._token_ok():
            return self._send(403, json.dumps({"error": "bad token"}))
        try:
            n = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa
            return self._send(400, json.dumps({"error": "bad json"}))
        rc, out, err = do_action(payload.get("action", ""), payload.get("env", ""))
        return self._send(200, json.dumps({"rc": rc, "output": out, "error": err}))


def main():
    global DISTRO, DEF_INTERVAL
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--interval", type=int, default=10, help="default UI auto-refresh seconds")
    ap.add_argument("--distro", default="Ubuntu", help="WSL distro for the root-shell button")
    ap.add_argument("--open", action="store_true", help="open the dashboard in your browser")
    args = ap.parse_args()
    DISTRO, DEF_INTERVAL = args.distro, args.interval
    url = "http://127.0.0.1:%d/" % args.port
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("=" * 60)
    print(" claude-dev dashboard")
    print("   %s" % url)
    print("   token: %s   (already embedded in the page)" % TOKEN)
    print("   bound to 127.0.0.1 only. Ctrl-C to stop.")
    print("=" * 60)
    sys.stdout.flush()
    if args.open:
        try:
            subprocess.Popen([CMDEXE, "/c", "start", "", url],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:  # noqa
            pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye.")


if __name__ == "__main__":
    main()
