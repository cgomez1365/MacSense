import http.server
import socketserver
import json
import subprocess
import re
import os
import ctypes
import time
import threading

PORT = 58249

# Mach Kernel CPU
libc = ctypes.CDLL(None)
mach_host_self = libc.mach_host_self
mach_host_self.restype = ctypes.c_uint32
host_statistics = libc.host_statistics
host_statistics.restype = ctypes.c_int
HOST_CPU_LOAD_INFO = 3
HOST_CPU_LOAD_INFO_COUNT = 4

class HostCpuLoadInfo(ctypes.Structure):
    _fields_ = [('cpu_ticks', ctypes.c_uint * 4)]

prev_cpu_ticks = None

def get_cpu_usage():
    global prev_cpu_ticks
    try:
        host = mach_host_self()
        info = HostCpuLoadInfo()
        count = ctypes.c_uint(HOST_CPU_LOAD_INFO_COUNT)
        ret = host_statistics(host, HOST_CPU_LOAD_INFO, ctypes.byref(info), ctypes.byref(count))
        curr_ticks = list(info.cpu_ticks) if ret == 0 else None
        if not curr_ticks: return 0.0
        if prev_cpu_ticks is None:
            prev_cpu_ticks = curr_ticks
            return 15.0
        deltas = [b - a for a, b in zip(prev_cpu_ticks, curr_ticks)]
        prev_cpu_ticks = curr_ticks
        total = sum(deltas)
        if total == 0: return 0.0
        busy = total - deltas[2]
        return max(0.0, min(100.0, round((busy / total) * 100.0, 1)))
    except Exception:
        return 0.0

def get_ram_stats():
    try:
        total_ram = int(subprocess.check_output('sysctl -n hw.memsize', shell=True).decode().strip())
        vm_stat = subprocess.check_output('vm_stat', shell=True).decode()
        def parse_pages(name):
            m = re.search(re.escape(name) + r':\s+(\d+)\.', vm_stat)
            return int(m.group(1)) * 4096 if m else 0
        free        = parse_pages('Pages free')
        speculative = parse_pages('Pages speculative')
        active      = parse_pages('Pages active')
        wired       = parse_pages('Pages wired down')
        compressed  = parse_pages('Pages occupied by compressor')
        available   = free + speculative
        used        = total_ram - available
        pct         = round((used / total_ram) * 100, 1)
        risk = "NORMAL"
        if pct >= 88:   risk = "CRITICAL"
        elif pct >= 75: risk = "HIGH"
        elif pct >= 60: risk = "MODERATE"
        return {
            "total_gb": round(total_ram/(1024**3),1), "used_gb": round(used/(1024**3),2),
            "free_gb": round(available/(1024**3),2), "percent": pct,
            "active_gb": round(active/(1024**3),2), "wired_gb": round(wired/(1024**3),2),
            "compressed_gb": round(compressed/(1024**3),2), "risk": risk
        }
    except Exception:
        return {"total_gb":8.0,"used_gb":0,"free_gb":8.0,"percent":0,"risk":"UNKNOWN","active_gb":0,"wired_gb":0,"compressed_gb":0}

def get_processes():
    try:
        out = subprocess.check_output(
            "ps -A -o pid,pcpu,rss,comm | awk 'NR>1' | sort -nr -k 3 | head -n 10",
            shell=True).decode()
        procs = []
        for line in out.strip().split('\n'):
            parts = line.strip().split(maxsplit=3)
            if len(parts) < 4: continue
            pid, cpu, rss_kb, comm = parts[0], parts[1], parts[2], parts[3]
            if not rss_kb.isdigit(): continue
            mb = round(int(rss_kb)/1024,1)
            try: cpu_f = round(float(cpu),1)
            except: cpu_f = 0.0
            procs.append({"pid":pid,"name":comm.split('/')[-1],"mb":mb,"cpu":cpu_f})
        return procs
    except Exception:
        return []

def get_gpu_stats():
    try:
        output = subprocess.check_output('ioreg -l | grep "PerformanceStatistics"', shell=True).decode()
        def extract(pattern, default='0'):
            m = re.search(pattern, output)
            return m.group(1) if m else default
        gpu_util = extract(r'"Device Utilization %"=(\d+)')
        if gpu_util == '0': gpu_util = extract(r'"GPU Activity\(%\)"=(\d+)')
        temp    = extract(r'"Temperature\(C\)"=(\d+)', '48')
        fan_rpm = extract(r'"Fan Speed\(RPM\)"=(\d+)', '0')
        core_clk= extract(r'"Core Clock\(MHz\)"=(\d+)', 'N/A')
        power   = extract(r'"Total Power\(W\)"=(\d+)', 'N/A')
        return {"activity":int(gpu_util) if gpu_util.isdigit() else 0,
                "temp_c":int(temp) if temp.isdigit() else 48,
                "fan_rpm":int(fan_rpm) if fan_rpm.isdigit() else 0,
                "core_clock_mhz":core_clk,"power_w":power}
    except Exception:
        return {"activity":0,"temp_c":45,"fan_rpm":0,"core_clock_mhz":"N/A","power_w":"N/A"}

def get_disk_stats():
    try:
        output = subprocess.check_output("df -h /", shell=True).decode().split('\n')[1]
        parts = output.split()
        return {"total":parts[1],"used":parts[2],"free":parts[3],"percent":int(parts[4].replace('%',''))}
    except Exception:
        return {"total":"N/A","used":"N/A","free":"N/A","percent":0}

_prev_net = {"bytes_in":0,"bytes_out":0,"ts":0}
def get_network_stats():
    global _prev_net
    try:
        out = subprocess.check_output(
            "netstat -ib | awk 'NR>1 {rx+=$7; tx+=$10} END {print rx, tx}'",
            shell=True).decode().strip().split()
        if len(out) < 2: return {"rx_mbps":0.0,"tx_mbps":0.0}
        b_in, b_out = int(out[0]), int(out[1])
        now = time.time()
        dt = now - _prev_net["ts"] if _prev_net["ts"] else 1
        rx = max(0,(b_in  - _prev_net["bytes_in"])  / dt / 1024 / 1024)
        tx = max(0,(b_out - _prev_net["bytes_out"]) / dt / 1024 / 1024)
        _prev_net = {"bytes_in":b_in,"bytes_out":b_out,"ts":now}
        return {"rx_mbps":round(rx,2),"tx_mbps":round(tx,2)}
    except Exception:
        return {"rx_mbps":0.0,"tx_mbps":0.0}

def background_watchdog():
    while True:
        try:
            r = get_ram_stats()
            if r["risk"] == "CRITICAL":
                print(f"[MacSense WATCHDOG] WARNING RAM CRITICAL {r['used_gb']}/{r['total_gb']} GB ({r['percent']}%)")
        except Exception:
            pass
        time.sleep(5)

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>MacSense // Nitro Dashboard</title>
<style>
  :root{--bg:#090a0f;--card:#131722;--card-border:#1e2638;--red:#ff1e44;--red-glow:rgba(255,30,68,0.4);--cyan:#00f0ff;--cyan-glow:rgba(0,240,255,0.35);--green:#00ff88;--orange:#ffb700;--text:#e2e8f0;--muted:#64748b;}
  *{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;}
  body{background:radial-gradient(circle at 50% 8%,#171d2d,var(--bg));color:var(--text);min-height:100vh;padding:18px 22px;}
  header{display:flex;justify-content:space-between;align-items:center;border-bottom:2px solid var(--card-border);padding-bottom:12px;margin-bottom:16px;}
  .brand{display:flex;align-items:center;gap:12px;}
  .hex{width:28px;height:28px;background:var(--red);clip-path:polygon(50% 0%,100% 25%,100% 75%,50% 100%,0% 75%,0% 25%);box-shadow:0 0 14px var(--red-glow);display:flex;align-items:center;justify-content:center;font-weight:900;color:#000;font-size:13px;}
  .brand-name{font-size:19px;font-weight:800;letter-spacing:3px;background:linear-gradient(90deg,#fff,#94a3b8);-webkit-background-clip:text;-webkit-text-fill-color:transparent;}
  .header-right{display:flex;align-items:center;gap:14px;}
  .live-pill{display:flex;align-items:center;gap:7px;font-size:10px;color:var(--green);background:rgba(0,255,136,0.08);padding:4px 11px;border-radius:20px;border:1px solid rgba(0,255,136,0.25);}
  .dot{width:6px;height:6px;background:var(--green);border-radius:50%;box-shadow:0 0 6px var(--green);animation:pulse 2s infinite;}
  .uptime{font-size:10px;color:var(--muted);font-weight:600;letter-spacing:0.5px;}
  @keyframes pulse{0%,100%{opacity:0.25}50%{opacity:1}}
  .grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:14px;}
  .grid-half{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px;}
  .card{background:var(--card);border:1px solid var(--card-border);border-radius:10px;padding:16px;position:relative;overflow:hidden;box-shadow:0 6px 20px rgba(0,0,0,0.4);}
  .card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,var(--red),transparent);}
  .card-title{font-size:10px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:12px;}
  .gauge-wrap{display:flex;flex-direction:column;align-items:center;}
  svg.gauge{width:110px;height:110px;}
  .bg-ring{fill:none;stroke:rgba(255,255,255,0.05);stroke-width:4;}
  .fg-ring{fill:none;stroke-width:4;stroke-linecap:round;transition:stroke-dasharray 0.7s ease;}
  .fg-cyan{stroke:var(--cyan);filter:drop-shadow(0 0 5px var(--cyan-glow));}
  .fg-red{stroke:var(--red);filter:drop-shadow(0 0 5px var(--red-glow));}
  .fg-ora{stroke:var(--orange);filter:drop-shadow(0 0 5px rgba(255,183,0,0.4));}
  .g-val{font-weight:800;fill:#fff;text-anchor:middle;}
  .g-sub{fill:var(--muted);text-anchor:middle;}
  .sub-row{display:flex;justify-content:space-around;border-top:1px solid rgba(255,255,255,0.05);padding-top:9px;margin-top:9px;text-align:center;}
  .sub-item .v{font-size:13px;font-weight:700;color:#fff;}
  .sub-item .l{font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:0.4px;}
  .bar-label{display:flex;justify-content:space-between;font-size:11px;font-weight:600;margin-bottom:5px;}
  .bar-bg{width:100%;height:9px;background:rgba(255,255,255,0.06);border-radius:5px;overflow:hidden;margin-bottom:10px;}
  .bar-fill{height:100%;border-radius:5px;transition:width 0.7s ease;}
  .bar-ram{background:linear-gradient(90deg,#ff9900,var(--red));box-shadow:0 0 7px var(--red-glow);}
  .bar-disk{background:linear-gradient(90deg,var(--cyan),#0088ff);box-shadow:0 0 7px var(--cyan-glow);}
  .risk-badge{font-size:9px;font-weight:700;padding:2px 7px;border-radius:4px;border:1px solid;text-transform:uppercase;transition:all 0.4s;}
  .risk-crit{color:var(--red)!important;border-color:var(--red)!important;animation:blink 1s infinite;}
  @keyframes blink{0%,100%{opacity:1}50%{opacity:0.35}}
  .alert-box{background:rgba(255,30,68,0.1);border:1px solid var(--red);border-radius:7px;padding:8px 12px;font-size:10px;color:#ff8899;display:none;align-items:center;gap:8px;margin-top:9px;font-weight:600;}
  .fan-row{display:flex;align-items:center;gap:14px;padding:7px 0;}
  .fan-icon{font-size:34px;display:inline-block;}
  .fan-spin-fast{animation:spin 0.7s linear infinite;}
  .fan-spin-slow{animation:spin 3s linear infinite;}
  @keyframes spin{100%{transform:rotate(360deg)}}
  .proc-table{width:100%;border-collapse:collapse;font-size:11px;}
  .proc-table th{text-align:left;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:0.8px;padding:4px 6px;border-bottom:1px solid var(--card-border);font-size:9px;}
  .proc-table td{padding:5px 6px;border-bottom:1px solid rgba(255,255,255,0.03);vertical-align:middle;}
  .proc-row:hover{background:rgba(255,255,255,0.03)!important;}
  .proc-name{max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600;display:block;}
  .proc-bar-bg{width:60px;height:5px;background:rgba(255,255,255,0.07);border-radius:3px;overflow:hidden;display:inline-block;vertical-align:middle;}
  .proc-bar-fill{height:100%;border-radius:3px;transition:width 0.5s ease;}
  .kill-btn{background:transparent;color:var(--red);border:1px solid var(--red);border-radius:3px;padding:2px 8px;cursor:pointer;font-weight:800;font-size:9px;letter-spacing:0.5px;transition:all 0.15s;}
  .kill-btn:hover{background:var(--red);color:#fff;box-shadow:0 0 8px var(--red-glow);}
  .net-row{display:flex;justify-content:space-around;margin-top:16px;}
  .net-stat{display:flex;flex-direction:column;align-items:center;gap:3px;text-align:center;}
  .net-val{font-size:26px;font-weight:800;color:#fff;line-height:1;}
  .btn-row{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;}
  .btn{border:none;border-radius:8px;padding:14px;font-size:11px;font-weight:800;letter-spacing:0.8px;text-transform:uppercase;cursor:pointer;display:flex;flex-direction:column;align-items:center;gap:3px;transition:all 0.2s;}
  .btn span.s{font-size:9px;font-weight:500;text-transform:none;opacity:0.75;letter-spacing:0;}
  .btn-blue{background:linear-gradient(135deg,#0ea5e9,#0369a1);color:#fff;}
  .btn-blue:hover{box-shadow:0 6px 20px rgba(14,165,233,0.5);transform:translateY(-2px);}
  .btn-orange{background:linear-gradient(135deg,#ff9900,#c05000);color:#fff;}
  .btn-orange:hover{box-shadow:0 6px 20px rgba(255,153,0,0.5);transform:translateY(-2px);}
  .btn-red{background:linear-gradient(135deg,#ff1e44,#be123c);color:#fff;}
  .btn-red:hover{box-shadow:0 6px 20px var(--red-glow);transform:translateY(-2px);}
  .btn:active{transform:scale(0.97);}
  #toast{position:fixed;bottom:20px;right:20px;background:#1e293b;border:1px solid #334155;padding:11px 16px;border-radius:8px;color:#fff;font-size:11px;font-weight:600;box-shadow:0 8px 24px rgba(0,0,0,0.5);transform:translateY(80px);opacity:0;transition:all 0.3s ease;max-width:280px;}
  #toast.show{transform:translateY(0);opacity:1;}
</style>
</head>
<body>
<header>
  <div class="brand">
    <div class="hex">M</div>
    <span class="brand-name">MACSENSE</span>
    <span style="font-size:9px;color:var(--red);background:rgba(255,30,68,0.1);border:1px solid var(--red);padding:2px 7px;border-radius:4px;letter-spacing:1px;">NITRO CONTROL</span>
  </div>
  <div class="header-right">
    <span class="uptime" id="uptime-display">UPTIME --:--:--</span>
    <div class="live-pill"><div class="dot"></div>LIVE MONITOR</div>
  </div>
</header>

<div class="grid4">
  <div class="card">
    <div class="card-title">CPU Performance</div>
    <div class="gauge-wrap">
      <svg class="gauge" viewBox="0 0 36 36">
        <path class="bg-ring" d="M18 2.1a15.9 15.9 0 0 1 0 31.8a15.9 15.9 0 0 1 0-31.8"/>
        <path id="cpu-ring" class="fg-ring fg-cyan" stroke-dasharray="0,100" d="M18 2.1a15.9 15.9 0 0 1 0 31.8a15.9 15.9 0 0 1 0-31.8"/>
        <text id="cpu-val" x="18" y="18.5" class="g-val">--%</text>
        <text x="18" y="24" class="g-sub">CPU LOAD</text>
      </svg>
    </div>
    <div class="sub-row">
      <div class="sub-item"><div id="cpu-cores" class="v">--</div><div class="l">Cores</div></div>
      <div class="sub-item"><div id="cpu-load" class="v">--</div><div class="l">Load 1m</div></div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">GPU Activity</div>
    <div class="gauge-wrap">
      <svg class="gauge" viewBox="0 0 36 36">
        <path class="bg-ring" d="M18 2.1a15.9 15.9 0 0 1 0 31.8a15.9 15.9 0 0 1 0-31.8"/>
        <path id="gpu-ring" class="fg-ring fg-red" stroke-dasharray="0,100" d="M18 2.1a15.9 15.9 0 0 1 0 31.8a15.9 15.9 0 0 1 0-31.8"/>
        <text id="gpu-val" x="18" y="18.5" class="g-val">--%</text>
        <text x="18" y="24" class="g-sub">GPU UTIL</text>
      </svg>
    </div>
    <div class="sub-row">
      <div class="sub-item"><div id="gpu-clock" class="v">--</div><div class="l">MHz</div></div>
      <div class="sub-item"><div id="gpu-power" class="v">--</div><div class="l">Watts</div></div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">Thermals &amp; Fan</div>
    <div class="gauge-wrap">
      <svg class="gauge" viewBox="0 0 36 36">
        <path class="bg-ring" d="M18 2.1a15.9 15.9 0 0 1 0 31.8a15.9 15.9 0 0 1 0-31.8"/>
        <path id="temp-ring" class="fg-ring fg-ora" stroke-dasharray="0,100" d="M18 2.1a15.9 15.9 0 0 1 0 31.8a15.9 15.9 0 0 1 0-31.8"/>
        <text id="temp-val" x="18" y="18.5" class="g-val">--C</text>
        <text x="18" y="24" class="g-sub">TEMP</text>
      </svg>
    </div>
    <div class="fan-row" style="justify-content:center;margin-top:2px;">
      <span id="fan-icon" class="fan-icon fan-spin-slow">⚙️</span>
      <div>
        <div id="fan-rpm" style="font-size:15px;font-weight:800;color:#fff;">-- RPM</div>
        <div style="font-size:9px;color:var(--muted);text-transform:uppercase;">Fan Speed</div>
      </div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">SSD Storage</div>
    <div style="margin-top:8px;">
      <div class="bar-label"><span>Used</span><span id="disk-text">--</span></div>
      <div class="bar-bg"><div id="disk-fill" class="bar-fill bar-disk" style="width:0%"></div></div>
    </div>
    <div class="sub-row">
      <div class="sub-item"><div id="disk-used" class="v">--</div><div class="l">Used</div></div>
      <div class="sub-item"><div id="disk-free" class="v">--</div><div class="l">Free</div></div>
      <div class="sub-item"><div id="disk-pct" class="v">--%</div><div class="l">Full</div></div>
    </div>
  </div>
</div>

<div class="grid-half">
  <div class="card">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;">
      <div class="card-title" style="margin:0;">RAM — Crash Hazard Monitor</div>
      <span id="ram-badge" class="risk-badge" style="color:var(--cyan);border-color:var(--cyan);">SCANNING</span>
    </div>
    <div class="bar-label"><span>Memory In Use</span><span id="ram-text">-- / 8.0 GB (--%)</span></div>
    <div class="bar-bg"><div id="ram-fill" class="bar-fill bar-ram" style="width:0%"></div></div>
    <div class="sub-row" style="margin-bottom:10px;">
      <div class="sub-item"><div id="ram-active" class="v">-- GB</div><div class="l">Active</div></div>
      <div class="sub-item"><div id="ram-wired" class="v">-- GB</div><div class="l">Wired</div></div>
      <div class="sub-item"><div id="ram-comp" class="v">-- GB</div><div class="l">Compressed</div></div>
      <div class="sub-item"><div id="ram-free" class="v">-- GB</div><div class="l">Free</div></div>
    </div>
    <div id="ram-alert" class="alert-box">WARNING RAM CRITICAL — Crash risk high. Use Smart or Emergency Purge now.</div>
  </div>
  <div class="card">
    <div class="card-title">Network Activity</div>
    <div class="net-row">
      <div class="net-stat">
        <div class="net-val" id="net-rx">0.00</div>
        <div style="font-size:11px;color:var(--green);font-weight:700;margin-top:2px;">▼ MB/s</div>
        <div style="font-size:9px;color:var(--muted);text-transform:uppercase;margin-top:2px;">Download</div>
      </div>
      <div style="width:1px;background:var(--card-border);"></div>
      <div class="net-stat">
        <div class="net-val" id="net-tx">0.00</div>
        <div style="font-size:11px;color:var(--cyan);font-weight:700;margin-top:2px;">▲ MB/s</div>
        <div style="font-size:9px;color:var(--muted);text-transform:uppercase;margin-top:2px;">Upload</div>
      </div>
    </div>
  </div>
</div>

<div class="card" style="margin-bottom:14px;">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;">
    <div class="card-title" style="margin:0;">Process Manager — Top Memory Consumers</div>
    <span style="font-size:9px;color:var(--muted);">Click KILL to force quit any process</span>
  </div>
  <table class="proc-table">
    <thead>
      <tr>
        <th>Process</th><th>PID</th><th>CPU %</th><th>RAM MB</th>
        <th style="text-align:center;">Usage</th><th style="text-align:center;">Action</th>
      </tr>
    </thead>
    <tbody id="proc-tbody">
      <tr><td colspan="6" style="color:var(--muted);padding:10px 6px;">Scanning processes...</td></tr>
    </tbody>
  </table>
</div>

<div class="btn-row">
  <button class="btn btn-blue" onclick="cleanDisk()">⚡ DISK CLEANUP<span class="s">Flush system cache files</span></button>
  <button class="btn btn-orange" onclick="purgeTopHogs()">🔥 SMART RAM PURGE<span class="s">Kill top 3 live memory hogs</span></button>
  <button class="btn btn-red" onclick="freeRAM()">🚨 EMERGENCY PURGE<span class="s">Kill Chrome · Claude · Slack</span></button>
</div>

<div id="toast"></div>
<script>
const SERVER_START = Date.now();
let _procs = [];

function toast(msg){const t=document.getElementById('toast');t.innerText=msg;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),3500);}

function updateUptime(){
  const s=Math.floor((Date.now()-SERVER_START)/1000);
  const h=String(Math.floor(s/3600)).padStart(2,'0');
  const m=String(Math.floor((s%3600)/60)).padStart(2,'0');
  const sec=String(s%60).padStart(2,'0');
  document.getElementById('uptime-display').textContent='UPTIME  '+h+':'+m+':'+sec;
}

async function tick(){
  try{
    const d=await fetch('/api/stats').then(r=>r.json());
    document.getElementById('cpu-val').textContent=d.cpu.percent+'%';
    document.getElementById('cpu-ring').setAttribute('stroke-dasharray',d.cpu.percent+',100');
    document.getElementById('cpu-cores').textContent=d.cpu.cores;
    document.getElementById('cpu-load').textContent=d.cpu.load_1m;
    document.getElementById('gpu-val').textContent=d.gpu.activity+'%';
    document.getElementById('gpu-ring').setAttribute('stroke-dasharray',d.gpu.activity+',100');
    document.getElementById('gpu-clock').textContent=d.gpu.core_clock_mhz;
    document.getElementById('gpu-power').textContent=d.gpu.power_w;
    const tp=Math.min(100,Math.round(d.gpu.temp_c));
    document.getElementById('temp-val').textContent=d.gpu.temp_c+'°C';
    document.getElementById('temp-ring').setAttribute('stroke-dasharray',tp+',100');
    const rpm=d.gpu.fan_rpm>0?d.gpu.fan_rpm:(d.gpu.temp_c>60?1600:950);
    document.getElementById('fan-rpm').textContent=rpm+(d.gpu.fan_rpm>0?' RPM':' RPM (est)');
    document.getElementById('fan-icon').className='fan-icon '+(d.gpu.temp_c>60?'fan-spin-fast':'fan-spin-slow');
    document.getElementById('ram-text').textContent=d.ram.used_gb+' / '+d.ram.total_gb+' GB ('+d.ram.percent+'%)';
    document.getElementById('ram-fill').style.width=d.ram.percent+'%';
    document.getElementById('ram-active').textContent=d.ram.active_gb+' GB';
    document.getElementById('ram-wired').textContent=d.ram.wired_gb+' GB';
    document.getElementById('ram-comp').textContent=d.ram.compressed_gb+' GB';
    document.getElementById('ram-free').textContent=d.ram.free_gb+' GB';
    const badge=document.getElementById('ram-badge');
    const isCrit=d.ram.risk==='CRITICAL';const isHigh=d.ram.risk==='HIGH';
    badge.textContent=d.ram.risk;
    badge.style.color=isCrit?'var(--red)':isHigh?'var(--orange)':'var(--cyan)';
    badge.style.borderColor=isCrit?'var(--red)':isHigh?'var(--orange)':'var(--cyan)';
    badge.className='risk-badge'+(isCrit?' risk-crit':'');
    document.getElementById('ram-alert').style.display=isCrit?'flex':'none';
    document.getElementById('disk-text').textContent=d.disk.used+' / '+d.disk.total;
    document.getElementById('disk-fill').style.width=d.disk.percent+'%';
    document.getElementById('disk-used').textContent=d.disk.used;
    document.getElementById('disk-free').textContent=d.disk.free;
    document.getElementById('disk-pct').textContent=d.disk.percent+'%';
    document.getElementById('net-rx').textContent=d.network.rx_mbps.toFixed(2);
    document.getElementById('net-tx').textContent=d.network.tx_mbps.toFixed(2);
    _procs=d.procs||[];
    const maxMB=_procs.length>0?_procs[0].mb:1;
    const tbody=document.getElementById('proc-tbody');
    if(_procs.length===0){tbody.innerHTML='<tr><td colspan="6" style="color:var(--muted);padding:10px 6px;">No data</td></tr>';return;}
    tbody.innerHTML=_procs.map((p,i)=>{
      const barW=Math.round((p.mb/maxMB)*100);
      const mc=p.mb>1500?'var(--red)':p.mb>600?'var(--orange)':'var(--green)';
      const cc=p.cpu>50?'var(--red)':p.cpu>20?'var(--orange)':'var(--text)';
      const rb=i===0?'rgba(255,30,68,0.05)':p.mb>600?'rgba(255,183,0,0.03)':'transparent';
      const icon=i===0?'🔴 ':i===1?'🟠 ':i===2?'🟡 ':'';
      return '<tr class="proc-row" style="background:'+rb+';"><td><span class="proc-name" title="'+p.name+'">'+icon+p.name+'</span></td><td style="color:var(--muted);font-size:10px;">'+p.pid+'</td><td style="color:'+cc+';font-weight:600;">'+p.cpu+'%</td><td style="color:'+mc+';font-weight:700;">'+p.mb+'</td><td style="text-align:center;"><div class="proc-bar-bg"><div class="proc-bar-fill" style="width:'+barW+'%;background:'+mc+';"></div></div></td><td style="text-align:center;"><button class="kill-btn" onclick="killProcess(\\\''+p.pid+'\\\',\\\''+p.name+'\\\')">KILL</button></td></tr>';
    }).join('');
  }catch(e){}
}

async function killProcess(pid,name){
  if(!confirm('Force quit "'+name+'"?\\n\\nUnsaved work in this process will be lost.'))return;
  toast('Killing '+name+'...');
  const r=await fetch('/api/kill-process',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pid})}).then(r=>r.json());
  toast(r.message);setTimeout(tick,800);
}

async function purgeTopHogs(){
  if(_procs.length===0){toast('No process data yet.');return;}
  const top3=_procs.slice(0,3).map(p=>'- '+p.name+' ('+p.mb+' MB)').join('\\n');
  if(!confirm('Smart RAM Purge - Kill top 3 memory hogs?\\n\\n'+top3+'\\n\\nUnsaved work will be lost.'))return;
  toast('Purging top hogs...');
  for(const p of _procs.slice(0,3)){
    await fetch('/api/kill-process',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pid:p.pid})});
  }
  toast('Top 3 processes killed. RAM freed.');setTimeout(tick,1000);
}

async function cleanDisk(){
  if(!confirm('Flush temporary cache files to free SSD space?'))return;
  toast('Cleaning caches...');
  const r=await fetch('/api/clean-disk',{method:'POST'}).then(r=>r.json());
  toast(r.message);tick();
}

async function freeRAM(){
  if(!confirm('Force quit Chrome, Claude, and Slack to free RAM?\\nSave your work first!'))return;
  toast('Emergency purge running...');
  const r=await fetch('/api/free-ram',{method:'POST'}).then(r=>r.json());
  toast(r.message);setTimeout(tick,1000);
}

setInterval(tick,1500);setInterval(updateUptime,1000);tick();updateUptime();
</script>
</body>
</html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/','/index.html'):
            self.send_response(200)
            self.send_header('Content-type','text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        elif self.path=='/api/stats':
            load1=os.getloadavg()[0]
            data={"cpu":{"percent":get_cpu_usage(),"cores":os.cpu_count() or 6,"load_1m":round(load1,2)},
                  "gpu":get_gpu_stats(),"ram":get_ram_stats(),"disk":get_disk_stats(),
                  "network":get_network_stats(),"procs":get_processes()}
            body=json.dumps(data).encode()
            self.send_response(200)
            self.send_header('Content-type','application/json')
            self.send_header('Content-length',len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404);self.end_headers()

    def do_POST(self):
        if self.path=='/api/clean-disk':
            subprocess.run("rm -rf ~/Library/Caches/*",shell=True)
            msg="Cache files cleared!"
        elif self.path=='/api/free-ram':
            subprocess.run("osascript -e 'quit app \"Google Chrome\"' 2>/dev/null",shell=True)
            subprocess.run("osascript -e 'quit app \"Claude\"' 2>/dev/null",shell=True)
            subprocess.run("osascript -e 'quit app \"Slack\"' 2>/dev/null",shell=True)
            msg="Chrome, Claude, Slack closed. RAM freed!"
        elif self.path=='/api/kill-process':
            cl=int(self.headers.get('Content-Length',0))
            req=json.loads(self.rfile.read(cl).decode())
            pid=str(req.get('pid',''))
            if pid.isdigit():
                subprocess.run("kill -9 "+pid,shell=True)
                msg="Process "+pid+" killed."
            else:
                msg="Invalid PID."
        else:
            self.send_response(404);self.end_headers();return
        body=json.dumps({"message":msg}).encode()
        self.send_response(200)
        self.send_header('Content-type','application/json')
        self.send_header('Content-length',len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self,*a):pass

class ReuseServer(socketserver.TCPServer):
    allow_reuse_address=True

if __name__=='__main__':
    threading.Thread(target=background_watchdog,daemon=True).start()
    print("[MacSense] Starting on port",PORT)
    with ReuseServer(('127.0.0.1',PORT),Handler) as srv:
        print("[MacSense] Live at http://127.0.0.1:"+str(PORT))
        srv.serve_forever()
