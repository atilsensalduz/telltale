#!/usr/bin/env python3
"""netwatch - tiny PingPlotter-style connectivity logger (macOS / Linux, stdlib only).

Every few seconds it probes 5 layers and logs the results to a CSV:
  gateway     ping to your router            -> Wi-Fi / local network
  cloudflare  ping to 1.1.1.1                -> ISP / internet reachability
  google      ping to 8.8.8.8                -> second public target (rules out one bad host)
  dns         UDP DNS query to 1.1.1.1       -> DNS health
  https       full HTTPS request (new conn)  -> what a browser actually experiences

Usage:
  python3 netwatch.py run                    # leave running in a Terminal, Ctrl+C to stop
  python3 netwatch.py report --hours 24      # builds netwatch.html with chart + outage list
"""
import argparse
import csv
import json
import os
import platform
import random
import re
import socket
import statistics
import struct
import subprocess
import threading
import time
import urllib.request
from datetime import datetime, timedelta

PROBES = ["gateway", "cloudflare", "google", "dns", "https"]
LABELS = {"gateway": "Router", "cloudflare": "1.1.1.1 ping", "google": "8.8.8.8 ping",
          "dns": "DNS query", "https": "HTTPS request"}
FIELDS = ["ts"] + PROBES


# ----------------------------------------------------------------- probes
def ping(host, timeout=2):
    if not host:
        return None
    # macOS: -W is milliseconds; Linux: seconds
    w = str(int(timeout * 1000)) if platform.system() == "Darwin" else str(int(timeout))
    try:
        out = subprocess.run(["ping", "-c", "1", "-W", w, host], capture_output=True,
                             text=True, timeout=timeout + 2).stdout
    except Exception:
        return None
    m = re.search(r"time[=<]([\d.]+)\s*ms", out)
    return float(m.group(1)) if m else None


def default_gateway():
    try:
        if platform.system() == "Darwin":
            out = subprocess.run(["route", "-n", "get", "default"], capture_output=True,
                                 text=True, timeout=3).stdout
            m = re.search(r"gateway:\s*(\S+)", out)
        else:
            out = subprocess.run(["ip", "route", "show", "default"], capture_output=True,
                                 text=True, timeout=3).stdout
            m = re.search(r"default via (\S+)", out)
        return m.group(1) if m else None
    except Exception:
        return None


def dns_probe(server="1.1.1.1", timeout=2):
    name = "www." + random.choice(["example", "cloudflare", "wikipedia", "apple", "debian"]) + ".com"
    tid = random.randrange(65536)
    q = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
    q += struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    t = time.perf_counter()
    try:
        s.sendto(q, (server, 53))
        data, _ = s.recvfrom(512)
        if struct.unpack(">H", data[:2])[0] != tid:
            return None
        return (time.perf_counter() - t) * 1000
    except Exception:
        return None
    finally:
        s.close()


def https_probe(url="https://www.gstatic.com/generate_204", timeout=4):
    # New connection each time: system DNS + TCP + TLS + HTTP, like a fresh browser request.
    t = time.perf_counter()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "netwatch"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read(1)
        return (time.perf_counter() - t) * 1000
    except Exception:
        return None


def diagnose(v):
    """v = [gateway, cloudflare, google, dns, https] (None = failed). Returns cause or None if OK."""
    g, c, go, d, h = v
    if g is None:
        return "Local network (Wi-Fi/router)"
    if c is None and go is None:
        return "ISP / upstream"
    if d is None:
        return "DNS"
    if h is None:
        return "Web path (HTTPS/proxy/VPN/site) - pings OK"
    return None


# ----------------------------------------------------------------- run
def cmd_run(args):
    log = os.path.expanduser(args.log)
    new = not os.path.exists(log)
    f = open(log, "a", newline="")
    w = csv.writer(f)
    if new:
        w.writerow(FIELDS)
        f.flush()
    print(f"netwatch logging to {log} every {args.interval}s - Ctrl+C to stop")
    try:
        while True:
            start = time.time()
            gw = default_gateway()
            jobs = {
                "gateway": lambda gw=gw: ping(gw),
                "cloudflare": lambda: ping("1.1.1.1"),
                "google": lambda: ping("8.8.8.8"),
                "dns": dns_probe,
                "https": https_probe,
            }
            res = {}

            def work(k, fn):
                res[k] = fn()

            ths = [threading.Thread(target=work, args=(k, fn)) for k, fn in jobs.items()]
            [t.start() for t in ths]
            [t.join() for t in ths]
            vals = [res.get(k) for k in PROBES]
            w.writerow([datetime.now().isoformat(timespec="seconds")] +
                       ["" if v is None else f"{v:.1f}" for v in vals])
            f.flush()
            cells = " | ".join(f"{LABELS[k]} {'FAIL' if v is None else f'{v:.0f}ms'}"
                               for k, v in zip(PROBES, vals))
            cause = diagnose(vals)
            print(f"{datetime.now():%H:%M:%S}  {cells}  {'<-- ' + cause if cause else ''}")
            time.sleep(max(0, args.interval - (time.time() - start)))
    except KeyboardInterrupt:
        print("\nstopped.")
    finally:
        f.close()


# ----------------------------------------------------------------- report
def load(log, hours):
    rows = []
    with open(log) as f:
        for r in csv.DictReader(f):
            try:
                t = datetime.fromisoformat(r["ts"])
                vals = [float(r[k]) if r[k] else None for k in PROBES]
            except Exception:
                continue
            rows.append((t, vals))
    if hours:
        cutoff = datetime.now() - timedelta(hours=hours)
        rows = [x for x in rows if x[0] >= cutoff]
    return rows


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else None


def find_outages(rows, min_len=2):
    outs, cur = [], []
    for t, v in rows + [(None, [0] * 5)]:  # sentinel flushes the last run
        cause = diagnose(v) if t else None
        if cause:
            cur.append((t, cause))
        else:
            if len(cur) >= min_len:
                causes = [c for _, c in cur]
                outs.append({"start": cur[0][0], "end": cur[-1][0], "n": len(cur),
                             "cause": max(set(causes), key=causes.count)})
            cur = []
    return outs


HTML = """<!doctype html><meta charset=utf-8><title>netwatch report</title>
<style>
body{font:14px -apple-system,system-ui,sans-serif;margin:24px;max-width:1100px;color:#222}
h1{font-size:20px} table{border-collapse:collapse;margin:12px 0} td,th{padding:4px 12px;border-bottom:1px solid #ddd;text-align:left}
canvas{width:100%;height:360px;border:1px solid #ddd;border-radius:6px}
.legend span{margin-right:16px}.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:5px}
.warn{background:#fff4d6;padding:8px 12px;border-radius:6px}
</style>
<h1>netwatch report</h1><p>__SPAN__</p>__WARN__
<div class=legend id=lg></div><canvas id=c></canvas>
<p style="color:#888">Red bands = at least one probe failed in that sample. Hover the chart for values.</p>
<h2>Summary</h2>__STATS__
<h2>Outages (2+ consecutive failed samples)</h2>__OUTS__
<script>
const D=__DATA__,names=__NAMES__,cols=["#2e7d32","#1565c0","#6a1b9a","#ef6c00","#c62828"];
const cv=document.getElementById('c'),ctx=cv.getContext('2d'),dpr=devicePixelRatio||1;
document.getElementById('lg').innerHTML=names.map((n,i)=>`<span><i class=dot style="background:${cols[i]}"></i>${n}</span>`).join('');
const M={l:50,r:10,t:10,b:24};let W,H,t0,t1,ymax;
function px(t){return M.l+(t-t0)/(t1-t0||1)*(W-M.l-M.r)}
function py(v){return H-M.b-Math.min(v,ymax)/ymax*(H-M.t-M.b)}
function draw(){W=cv.clientWidth;H=cv.clientHeight;cv.width=W*dpr;cv.height=H*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.clearRect(0,0,W,H);if(!D.length)return;t0=D[0][0];t1=D[D.length-1][0];
 const all=D.flatMap(r=>r.slice(1)).filter(x=>x!==null).sort((a,b)=>a-b);
 ymax=Math.max(100,(all[Math.floor(all.length*0.99)]||100)*1.2);
 ctx.font="11px sans-serif";ctx.fillStyle="#888";ctx.strokeStyle="#eee";
 for(let i=0;i<=4;i++){const v=ymax*i/4,y=py(v);ctx.beginPath();ctx.moveTo(M.l,y);ctx.lineTo(W-M.r,y);ctx.stroke();ctx.fillText(Math.round(v)+" ms",4,y+4)}
 for(let i=0;i<=6;i++){const t=t0+(t1-t0)*i/6;ctx.fillText(new Date(t).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}),px(t)-14,H-6)}
 const bw=Math.max(2,(W-M.l-M.r)/D.length);ctx.fillStyle="rgba(211,47,47,.25)";
 D.forEach(r=>{if(r.slice(1).some(x=>x===null))ctx.fillRect(px(r[0])-bw/2,M.t,bw,H-M.t-M.b)});
 for(let k=1;k<=5;k++){ctx.strokeStyle=cols[k-1];ctx.lineWidth=1.2;ctx.beginPath();let pen=false;
  D.forEach(r=>{if(r[k]===null){pen=false;return}const x=px(r[0]),y=py(r[k]);pen?ctx.lineTo(x,y):ctx.moveTo(x,y);pen=true});ctx.stroke()}}
cv.onmousemove=e=>{const x=e.offsetX,t=t0+(x-M.l)/(W-M.l-M.r)*(t1-t0);let b=D[0];D.forEach(r=>{if(Math.abs(r[0]-t)<Math.abs(b[0]-t))b=r});
 cv.title=new Date(b[0]).toLocaleTimeString()+"\\n"+names.map((n,i)=>n+": "+(b[i+1]===null?"FAIL":b[i+1].toFixed(0)+" ms")).join("\\n")};
addEventListener('resize',draw);draw();
</script>"""


def cmd_report(args):
    log = os.path.expanduser(args.log)
    rows = load(log, args.hours)
    if not rows:
        print("no data in that time range")
        return
    stats = "<table><tr><th>Probe<th>Loss<th>Median<th>95th pct</tr>"
    for i, k in enumerate(PROBES):
        ok = [v[i] for _, v in rows if v[i] is not None]
        loss = 100 * (len(rows) - len(ok)) / len(rows)
        med = f"{statistics.median(ok):.0f} ms" if ok else "-"
        p95 = f"{pct(ok, .95):.0f} ms" if ok else "-"
        stats += f"<tr><td>{LABELS[k]}<td>{loss:.1f}%<td>{med}<td>{p95}</tr>"
    stats += "</table>"

    outs = find_outages(rows)
    if outs:
        iv = statistics.median([(rows[i + 1][0] - rows[i][0]).total_seconds()
                                for i in range(len(rows) - 1)] or [2])
        o = "<table><tr><th>Start<th>End<th>~Duration<th>Likely cause</tr>"
        for x in outs:
            o += (f"<tr><td>{x['start']:%a %H:%M:%S}<td>{x['end']:%H:%M:%S}"
                  f"<td>{int(x['n'] * iv)} s<td>{x['cause']}</tr>")
        o += "</table>"
    else:
        o = "<p>None found.</p>"

    warn = ""
    if all(v[0] is None for _, v in rows):
        warn = ('<p class=warn>The router never answered ping (some routers block ICMP). '
                'Ignore the "Local network" diagnosis in that case.</p>')

    data = [[int(t.timestamp() * 1000)] + v for t, v in rows]
    html = (HTML.replace("__SPAN__", f"{rows[0][0]:%Y-%m-%d %H:%M} to {rows[-1][0]:%Y-%m-%d %H:%M} "
                                     f"({len(rows)} samples)")
            .replace("__WARN__", warn).replace("__STATS__", stats).replace("__OUTS__", o)
            .replace("__DATA__", json.dumps(data))
            .replace("__NAMES__", json.dumps([LABELS[k] for k in PROBES])))
    out = os.path.expanduser(args.out)
    with open(out, "w") as f:
        f.write(html)
    print(f"wrote {out} ({len(outs)} outages found)")
    if platform.system() == "Darwin":
        subprocess.run(["open", out])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--interval", type=float, default=2)
    r.add_argument("--log", default="~/netwatch.csv")
    r.set_defaults(fn=cmd_run)
    p = sub.add_parser("report")
    p.add_argument("--log", default="~/netwatch.csv")
    p.add_argument("--out", default="~/netwatch.html")
    p.add_argument("--hours", type=float, default=24)
    p.set_defaults(fn=cmd_report)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
