/* MacSense page. The native app calls MacSense.init(info) once and MacSense.onSample(sample) every
   second. The page asks the app to act through window.webkit.messageHandlers.macsense; that's
   the only way out of this page, and the app checks every request again before acting. */
(function () {
  'use strict';

  const { TimeChart, Sparkline, Clock, Tooltip, tooltipRow, fmt, el } = window.MSCharts;
  const $ = (id) => document.getElementById(id);
  const css = getComputedStyle(document.documentElement);
  const color = (name) => css.getPropertyValue('--' + name).trim();
  const C = {
    s1: color('series-1'), s2: color('series-2'), s3: color('series-3'), s4: color('series-4'),
    good: color('good'), warning: color('warning'), serious: color('serious'), critical: color('critical'),
  };
  const GiB = 1024 ** 3;
  const KEEP_MS = 15 * 60 * 1000 + 10000;
  const SPARK_POINTS = 60;
  const RANGE_TEXT = { 60: 'the last minute', 300: 'the last 5 minutes', 900: 'the last 15 minutes' };
  const PRESSURE = { 1: { name: 'Normal', tone: 'good' }, 2: { name: 'Warning', tone: 'warning' }, 4: { name: 'Critical', tone: 'critical' } };
  const THERMAL = [
    { name: 'Nominal', tone: 'good' }, { name: 'Fair', tone: 'warning' },
    { name: 'Serious', tone: 'serious' }, { name: 'Critical', tone: 'critical' },
  ];

  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.macsense;
  const state = {
    info: null, history: [], last: null, volumes: [], procs: null, icons: new Map(),
    range: 60, paused: false, sort: 'memory', lastArrival: 0, gpuKeys: '', tempKeys: '', volumeKeys: '', itReport: null,
    sparks: { cpu: [], mem: [], net: [], gpu: [], temp: [] },
  };

  // ---------------------------------------------------------------- icons (built as DOM, never parsed from strings)
  const SVG = 'http://www.w3.org/2000/svg';
  const ICON_PATHS = {
    good: ['M8 1.5a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13Z M4.6 8.2 5.7 7.1l1.4 1.4 3.2-3.2 1.1 1.1-4.3 4.3Z', 'evenodd'],
    warning: ['M8 1.8 15 14H1Z M7.25 5.8h1.5v4.1h-1.5Z M8 11.1a.9.9 0 1 1 0 1.8.9.9 0 0 1 0-1.8Z', 'evenodd'],
    critical: ['M5.2 1.5h5.6l3.7 3.7v5.6l-3.7 3.7H5.2l-3.7-3.7V5.2Z M7.25 4.3h1.5v4.9h-1.5Z M8 10.4a.9.9 0 1 1 0 1.8.9.9 0 0 1 0-1.8Z', 'evenodd'],
    lock: ['M5 7V5a3 3 0 0 1 6 0v2h.5A1.5 1.5 0 0 1 13 8.5v5A1.5 1.5 0 0 1 11.5 15h-7A1.5 1.5 0 0 1 3 13.5v-5A1.5 1.5 0 0 1 4.5 7Zm1.5 0h3V5a1.5 1.5 0 0 0-3 0Z', 'evenodd'],
    info: ['M8 1.5a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13Z M7.25 7h1.5v4.5h-1.5Z M8 4.2a.9.9 0 1 1 0 1.8.9.9 0 0 1 0-1.8Z', 'evenodd'],
  };
  ICON_PATHS.serious = ICON_PATHS.warning;

  function icon(name) {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', ICON_PATHS[name][0]);
    path.setAttribute('fill-rule', ICON_PATHS[name][1]);
    path.setAttribute('fill', 'currentColor');
    svg.append(path);
    return svg;
  }

  /** Drive pictures, drawn as outlines: startup/internal disk, USB or external drive, disk image. */
  function driveIcon(kind) {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 34 34');
    svg.setAttribute('class', 'volume-icon');
    svg.setAttribute('aria-hidden', 'true');
    const shapes = {
      internal: [['rect', { x: 4, y: 8, width: 26, height: 18, rx: 4 }], ['circle', { cx: 24.5, cy: 20.5, r: 1.6, fill: 'currentColor' }], ['path', { d: 'M4.5 16.5h25' }]],
      external: [['rect', { x: 10, y: 11, width: 14, height: 19, rx: 3 }], ['path', { d: 'M13 11V5.5h8V11 M15.5 7.5h1 M17.5 7.5h1' }], ['circle', { cx: 17, cy: 24, r: 1.6, fill: 'currentColor' }]],
      image: [['circle', { cx: 17, cy: 17, r: 12 }], ['circle', { cx: 17, cy: 17, r: 3.5 }]],
    }[kind];
    for (const [tag, attrs] of shapes) {
      const shape = document.createElementNS(SVG, tag);
      shape.setAttribute('fill', 'none');
      shape.setAttribute('stroke', 'currentColor');
      shape.setAttribute('stroke-width', '1.6');
      shape.setAttribute('stroke-linejoin', 'round');
      for (const [k, v] of Object.entries(attrs)) shape.setAttribute(k, v);
      svg.append(shape);
    }
    return svg;
  }

  /** A status always carries an icon and a word, never colour alone. Rebuilt only when it changes. */
  function setStatus(node, status, suffix) {
    const signature = status ? status.tone + status.name + (suffix || '') : '';
    if (node.dataset.signature === signature) return;
    node.dataset.signature = signature;
    node.replaceChildren();
    if (!status) { node.className = 'status'; node.textContent = '—'; return; }
    node.className = 'status tone-' + status.tone;
    node.append(icon(status.tone), el('span', null, suffix ? `${status.name} ${suffix}` : status.name));
  }

  function setValue(id, main, unit) {
    const node = $(id);
    node.textContent = main;
    if (unit) node.append(el('small', null, unit));
  }

  /** Fill carries severity (warning from 80%, critical from 90%) only where fullness is the problem. */
  function setMeter(meter, fraction, severity = true) {
    const f = Math.max(0, Math.min(1, fraction || 0));
    meter.firstElementChild.style.width = (f * 100).toFixed(1) + '%';
    meter.classList.toggle('warn', severity && f >= 0.8 && f < 0.9);
    meter.classList.toggle('crit', severity && f >= 0.9);
  }

  function shortGpu(name) {
    if (!name) return 'GPU';
    if (/^Intel/i.test(name)) return 'Intel graphics';
    return name.replace(/^(AMD|NVIDIA)\s+/i, '');
  }

  // ---------------------------------------------------------------- charts
  const charts = {};
  function buildCharts() {
    // The scale follows the traffic: a quiet link reads in kbps, a download in Mbps.
    charts.net = new TimeChart($('chart-net'), {
      height: 240, minTop: 0.05, legend: $('net-legend'),
      unit: (top) => (top < 1 ? 'kbps' : 'Mbps'),
      axis: (v, top) => (top < 1 ? String(Math.round(v * 1000)) : String(+v.toFixed(2))),
      series: [{ key: 'rx', label: 'Download', color: C.s1 }, { key: 'tx', label: 'Upload', color: C.s2 }],
      format: fmt.mbps, ariaLabel: 'Network speed over time, download and upload',
    });
    charts.cpu = new TimeChart($('chart-cpu'), {
      height: 170, yMax: 100, stacked: true, legend: $('cpu-legend'), totalLabel: 'Total',
      series: [{ key: 'cpuUser', label: 'User', color: C.s1 }, { key: 'cpuSys', label: 'System', color: C.s2 }],
      format: fmt.pct, axis: (v) => v + '%', ariaLabel: 'CPU use over time, user and system',
    });
    charts.mem = new TimeChart($('chart-mem'), {
      height: 150, yMax: 8,
      series: [{ key: 'memUsed', label: 'Memory used', color: C.s1 }],
      format: (v) => v.toFixed(2) + ' GB', axis: (v) => v + ' GB',
      band: { key: 'pressure', label: 'Pressure', colors: { 1: C.good, 2: C.warning, 4: C.critical }, names: { 1: 'Normal', 2: 'Warning', 4: 'Critical' } },
      ariaLabel: 'Memory used over time, with the memory pressure level underneath',
    });
    // Lines only: two washes over the same stretch blend into a colour neither series has.
    charts.gpu = new TimeChart($('chart-gpu'), {
      height: 130, yMax: 100, area: false, legend: $('gpu-legend'), series: [],
      format: fmt.pct, axis: (v) => v + '%', ariaLabel: 'Graphics processor use over time',
    });
    charts.temp = new TimeChart($('chart-temp'), {
      height: 130, yMax: 100, area: false, legend: $('temp-legend'), series: [],
      format: fmt.temp, axis: (v) => v + '°', ariaLabel: 'Temperatures over time in degrees Celsius',
    });
    $('net-key-down').style.background = C.s1;
    $('net-key-up').style.background = C.s2;
    $('band-good').style.background = C.good;
    $('band-warning').style.background = C.warning;
    $('band-critical').style.background = C.critical;
  }

  const sparks = {};
  function buildSparks() {
    sparks.cpu = new Sparkline($('spark-cpu'), C.s1);
    sparks.mem = new Sparkline($('spark-mem'), C.s1);
    sparks.net = new Sparkline($('spark-net'), C.s1);
    sparks.gpu = new Sparkline($('spark-gpu'), C.s1);
    sparks.temp = new Sparkline($('spark-temp'), C.s1);
  }

  function spark(name, value, max) {
    const values = state.sparks[name];
    values.push(value == null ? null : value);
    if (values.length > SPARK_POINTS) values.shift();
    sparks[name].draw(values, max);
  }

  // ---------------------------------------------------------------- data in
  function init(info) {
    state.info = info;
    $('machine-line').textContent = [info.modelName, info.cpu, Math.round(info.memTotal / GiB) + ' GB memory', info.os].filter(Boolean).join(' · ');
    $('machine-line').title = $('machine-line').textContent;
    $('app-version').textContent = info.appVersion ? 'v' + info.appVersion : '';
    charts.mem.o.yMax = info.memTotal / GiB;
    updateUptime();
  }

  function onSample(sample) {
    state.lastArrival = performance.now();
    state.last = sample;
    if (sample.volumes) state.volumes = sample.volumes;
    if (sample.procs) {
      state.procs = sample.procs;
      for (const [path, url] of Object.entries(sample.procs.icons || {})) state.icons.set(path, url);
    }
    syncDynamicSeries(sample);
    remember(sample);
    const rangeMs = state.range * 1000;
    for (const chart of Object.values(charts)) chart.setData(state.history, rangeMs);
    Clock.push(sample.t);

    renderTiles(sample);
    renderNetwork(sample);
    renderCPU(sample);
    renderMemory(sample);
    renderGraphics(sample);
    if (sample.volumes) renderVolumes();
    if (sample.procs) renderProcesses();
    updateLive();
  }

  function remember(s) {
    const cpu = s.cpu || {}, mem = s.mem || {}, net = s.net || {}, th = s.thermal || {}, gpus = s.gpu || [];
    const point = {
      t: s.t,
      cpuUser: cpu.ready ? cpu.user : null,
      cpuSys: cpu.ready ? cpu.system : null,
      memUsed: mem.used != null ? mem.used / GiB : null,
      pressure: mem.pressure != null ? mem.pressure : null,
      rx: net.ready ? net.rx * 8 / 1e6 : null,
      tx: net.ready ? net.tx * 8 / 1e6 : null,
      cpuC: th.cpuC != null ? th.cpuC : null,
      gpuC: gpuTemperature(s),
    };
    gpus.slice(0, 3).forEach((g, i) => { point['gpu' + i] = g.util != null ? g.util : null; });
    const history = state.history;
    history.push(point);
    const cutoff = s.t - KEEP_MS;
    let drop = 0;
    while (drop < history.length && history[drop].t < cutoff) drop++;
    if (drop) history.splice(0, drop);
  }

  function gpuTemperature(s) {
    const th = s.thermal || {};
    if (th.gpuC != null) return th.gpuC;
    const gpu = (s.gpu || []).find((g) => g.tempC != null);
    return gpu ? gpu.tempC : null;
  }

  /** GPU and temperature series depend on what this Mac reports; set them once they're known. */
  function syncDynamicSeries(s) {
    const gpus = (s.gpu || []).slice(0, 3);
    const gpuKeys = gpus.map((g) => g.name).join('|');
    if (gpuKeys !== state.gpuKeys) {
      state.gpuKeys = gpuKeys;
      const colors = [C.s1, C.s2, C.s3];
      charts.gpu.setSeries(gpus.map((g, i) => ({ key: 'gpu' + i, label: shortGpu(g.name), color: colors[i] })));
    }
    const temps = [];
    if ((s.thermal || {}).cpuC != null) temps.push({ key: 'cpuC', label: 'CPU', color: C.s1 });
    if (gpuTemperature(s) != null) temps.push({ key: 'gpuC', label: 'GPU', color: C.s2 });
    const tempKeys = temps.map((t) => t.key).join('|');
    if (tempKeys !== state.tempKeys) {
      state.tempKeys = tempKeys;
      charts.temp.setSeries(temps);
    }
  }

  // ---------------------------------------------------------------- summary tiles
  function renderTiles(s) {
    const cpu = s.cpu || {}, mem = s.mem || {}, net = s.net || {}, th = s.thermal || {}, gpus = s.gpu || [];
    const info = state.info || {};

    const busy = cpu.ready ? cpu.user + cpu.system : null;
    setValue('kpi-cpu', fmt.pct(busy));
    $('kpi-cpu-sub').textContent = cpu.load ? `Load ${cpu.load[0].toFixed(2)} · ${info.logicalCores || (cpu.cores || []).length} threads` : 'Measuring…';
    spark('cpu', busy, 100);

    setValue('kpi-mem', fmt.gib(mem.used), info.memTotal ? `of ${Math.round(info.memTotal / GiB)} GB` : '');
    setStatus($('kpi-mem-sub'), PRESSURE[mem.pressure], 'pressure');
    spark('mem', mem.used != null ? mem.used / GiB : null, info.memTotal ? info.memTotal / GiB : null);

    const primary = (net.ifaces || []).find((i) => i.name === net.primary);
    setValue('kpi-net', net.ready ? '↓ ' + fmt.mbps(net.rx * 8 / 1e6) : '—');
    $('kpi-net-sub').textContent = net.ready ? `↑ ${fmt.mbps(net.tx * 8 / 1e6)} · ${primary ? primary.label : 'no connection'}` : 'Measuring…';
    spark('net', net.ready ? net.rx * 8 / 1e6 : null);

    const startup = state.volumes.find((v) => v.root);
    const others = state.volumes.filter((v) => !v.root);
    setValue('kpi-disk', startup ? fmt.storage(startup.free) : '—', startup ? 'free' : '');
    $('kpi-disk-sub').textContent = startup
      ? `${Math.round(startup.used / startup.total * 100)}% used` + (others.length ? ` · +${others.length} drive${others.length > 1 ? 's' : ''}` : '')
      : 'Reading volumes…';
    setMeter($('kpi-disk-meter'), startup ? startup.used / startup.total : 0);

    const gpu = gpus[0];
    setValue('kpi-gpu', gpu && gpu.util != null ? fmt.pct(gpu.util) : '—');
    $('kpi-gpu-sub').textContent = gpu ? [shortGpu(gpu.name), gpu.tempC != null ? fmt.temp(gpu.tempC) : null].filter(Boolean).join(' · ') : 'No statistics reported';
    spark('gpu', gpu ? gpu.util : null, 100);

    const fan = (th.fans || [])[0];
    setValue('kpi-temp', th.cpuC != null ? fmt.temp(th.cpuC) : '—', th.cpuC != null ? 'CPU' : '');
    $('kpi-temp-sub').textContent = [fan ? 'Fan ' + fmt.rpm(fan.rpm) : null, THERMAL[th.state] ? THERMAL[th.state].name : null].filter(Boolean).join(' · ') || 'Not reported';
    spark('temp', th.cpuC, 100);
  }

  // ---------------------------------------------------------------- network
  function renderNetwork(s) {
    const net = s.net || {};
    const ifaces = net.ifaces || [];
    const primary = ifaces.find((i) => i.name === net.primary);
    $('net-sub').textContent = primary
      ? `${primary.label} (${primary.name})${primary.ipv4 ? ' · ' + primary.ipv4 : ''}. Physical links only: loopback and VPN tunnels aren't counted.`
      : 'No active connection.';
    $('net-down').textContent = net.ready ? fmt.mbps(net.rx * 8 / 1e6) : '—';
    $('net-up').textContent = net.ready ? fmt.mbps(net.tx * 8 / 1e6) : '—';

    let peakDown = null, peakUp = null;
    const from = s.t - state.range * 1000;
    for (let i = state.history.length - 1; i >= 0 && state.history[i].t >= from; i--) {
      const p = state.history[i];
      if (p.rx != null) peakDown = Math.max(peakDown || 0, p.rx);
      if (p.tx != null) peakUp = Math.max(peakUp || 0, p.tx);
    }
    $('net-peak-down').textContent = fmt.mbps(peakDown);
    $('net-peak-up').textContent = fmt.mbps(peakUp);
    $('net-total-down').textContent = fmt.storage(net.sessionRx);
    $('net-total-up').textContent = fmt.storage(net.sessionTx);

    const list = $('net-ifaces');
    if (list.childElementCount !== ifaces.length) {
      list.replaceChildren(...ifaces.map(() => {
        const row = el('div', 'iface');
        row.append(el('span', 'iface-name'), el('span', 'iface-meta'), el('span', 'iface-rate'));
        return row;
      }));
    }
    ifaces.forEach((i, index) => {
      const [name, meta, rate] = list.children[index].children;
      name.textContent = i.label;
      meta.textContent = [i.name, i.ipv4, i.name === net.primary ? 'in use' : null].filter(Boolean).join(' · ');
      rate.textContent = i.rx != null ? `↓ ${fmt.mbps(i.rx * 8 / 1e6)}   ↑ ${fmt.mbps(i.tx * 8 / 1e6)}` : 'idle';
    });
  }

  // ---------------------------------------------------------------- CPU
  function renderCPU(s) {
    const cpu = s.cpu || {};
    const info = state.info || {};
    $('cpu-sub').textContent = cpu.ready
      ? `${fmt.pct(cpu.user + cpu.system)} busy · load average ${cpu.load.map((v) => v.toFixed(2)).join(', ')} (1, 5, 15 min)`
      : 'Measuring…';
    const cores = cpu.cores || [];
    const host = $('cpu-threads');
    if (host.childElementCount !== cores.length) {
      host.replaceChildren(...cores.map((_, i) => {
        const bar = el('div', 'thread');
        bar.tabIndex = 0;
        bar.setAttribute('role', 'listitem');
        bar.append(el('span', 'thread-fill'));
        const show = (x, y) => Tooltip.show(bar, x, y, [tooltipRow(C.s1, fmt.pct(+bar.dataset.value), `Thread ${i + 1}`)]);
        bar.addEventListener('pointermove', (e) => show(e.clientX, e.clientY));
        bar.addEventListener('pointerleave', () => Tooltip.hide(bar));
        bar.addEventListener('focus', () => { const r = bar.getBoundingClientRect(); show(r.left + r.width / 2, r.top); });
        bar.addEventListener('blur', () => Tooltip.hide(bar));
        return bar;
      }));
      $('cpu-thread-axis').replaceChildren(...cores.map((_, i) => el('span', null, String(i + 1))));
      $('threads-note').textContent = info.physicalCores ? `${cores.length} threads on ${info.physicalCores} cores` : `${cores.length} threads`;
    }
    cores.forEach((v, i) => {
      const bar = host.children[i];
      bar.dataset.value = v;
      bar.firstElementChild.style.height = Math.max(2, Math.min(100, v)) + '%';
      bar.setAttribute('aria-label', `Thread ${i + 1}: ${fmt.pct(v)}`);
    });
  }

  // ---------------------------------------------------------------- memory
  function renderMemory(s) {
    const m = s.mem || {};
    if (m.total == null) return;
    setStatus($('mem-pressure'), PRESSURE[m.pressure], 'pressure');
    $('mem-sub').textContent = `${fmt.gib(m.used)} used of ${fmt.gib(m.total)}` + (m.availablePct != null ? ` · macOS rates ${m.availablePct}% as available` : '');

    const parts = [
      ['App memory', m.app, C.s1], ['Wired', m.wired, C.s2], ['Compressed', m.compressed, C.s3], ['Cached files', m.cached, C.s4],
    ];
    const stack = $('mem-stack');
    if (!stack.childElementCount) {
      parts.forEach(() => stack.append(el('span')));
      stack.append(el('span', 'free'));
    }
    parts.forEach(([, v, c], i) => { stack.children[i].style.flexGrow = String(Math.max(0, v)); stack.children[i].style.background = c; });
    stack.children[4].style.flexGrow = String(Math.max(0, m.free));
    stack.setAttribute('aria-label', parts.map(([n, v]) => `${n} ${fmt.gib(v)}`).join(', ') + `, free ${fmt.gib(m.free)}`);

    const legend = $('mem-legend');
    const entries = [...parts, ['Free', m.free, null]];
    if (!legend.childElementCount) {
      legend.append(...entries.map(([name, , c]) => {
        const item = el('li');
        const swatch = el('span', c ? 'swatch' : 'swatch swatch-free');
        if (c) swatch.style.background = c;
        item.append(swatch, el('span', null, name), el('span', 'v'));
        return item;
      }));
    }
    entries.forEach(([, v], i) => { legend.children[i].lastElementChild.textContent = fmt.gib(v); });

    if (m.swapTotal != null) {
      $('mem-swap-text').textContent = m.swapTotal > 0 ? `${fmt.gib(m.swapUsed)} of ${fmt.gib(m.swapTotal)}` : 'Not in use';
      // Neutral: macOS grows swap as needed, so "80% of swap" isn't a warning. Pressure is the verdict.
      setMeter($('mem-swap-meter'), m.swapTotal > 0 ? m.swapUsed / m.swapTotal : 0, false);
    }
  }

  // ---------------------------------------------------------------- graphics & thermals
  function thermalCell(id, value, sub) {
    const cell = $(id);
    cell.querySelector('.v').textContent = value;
    cell.querySelector('.s').textContent = sub || '';
  }

  function renderGraphics(s) {
    const gpus = s.gpu || [], th = s.thermal || {};
    $('gpu-sub').textContent = gpus.length
      ? gpus.map((g) => g.name + (g.powerW != null ? ` (${Math.round(g.powerW)} W)` : '')).join(' · ')
      : 'This Mac reports no GPU statistics.';
    const gpuC = gpuTemperature(s);
    thermalCell('th-cpu', th.cpuC != null ? fmt.temp(th.cpuC) : 'Not reported', th.cpuC != null ? 'SMC sensor' : "This Mac doesn't expose it");
    thermalCell('th-gpu', gpuC != null ? fmt.temp(gpuC) : 'Not reported', gpuC != null ? (gpus[0] && gpus[0].name ? shortGpu(gpus[0].name) : 'SMC sensor') : "This Mac doesn't expose it");
    const fan = (th.fans || [])[0];
    const fanCell = $('th-fan');
    if (fan) {
      thermalCell('th-fan', fmt.rpm(fan.rpm), fan.min != null && fan.max != null ? `${fmt.int(fan.min)}–${fmt.int(fan.max)} rpm` : 'SMC sensor');
      const span = fan.max != null && fan.min != null && fan.max > fan.min ? (fan.rpm - fan.min) / (fan.max - fan.min) : 0;
      fanCell.querySelector('.meter').hidden = false;
      setMeter(fanCell.querySelector('.meter'), span);
    } else {
      thermalCell('th-fan', 'Not reported', "No fan sensor on this Mac");
      fanCell.querySelector('.meter').hidden = true;
    }
    setStatus($('th-state-chip'), THERMAL[th.state]);
  }

  // ---------------------------------------------------------------- storage
  function volumeKind(v) {
    if (v.root) return 'Startup disk';
    if (v.bus === 'Virtual Interface') return 'Disk image';
    if (v.internal) return 'Internal';
    if (!v.local) return 'Network volume';
    return v.bus ? `${v.bus} drive` : 'External drive';
  }

  function renderVolumes() {
    const volumes = state.volumes;
    const count = volumes.length;
    $('storage-sub').textContent = `${count} ${count === 1 ? 'volume' : 'volumes'} mounted. Sizes in Finder's units (1 GB = 1,000,000,000 bytes).`;
    const keys = volumes.map((v) => v.path + '|' + v.name + '|' + v.ejectable).join('/');
    const list = $('volumes');
    if (keys !== state.volumeKeys) {
      state.volumeKeys = keys;
      list.replaceChildren(...volumes.map(buildVolume));
    }
    volumes.forEach((v, i) => updateVolume(list.children[i], v));
  }

  function buildVolume(v) {
    const item = el('li', 'volume');
    const kind = v.root || v.internal ? 'internal' : v.bus === 'Virtual Interface' ? 'image' : 'external';
    const name = el('div', 'volume-name', v.name);
    name.title = v.path;
    const meta = el('div', 'volume-kind', [volumeKind(v), v.device, v.format].filter(Boolean).join(' · '));
    const pct = el('div', 'volume-pct');
    const meter = el('div', 'meter');
    meter.append(el('span'));
    const foot = el('div', 'volume-foot');
    const text = el('span', 'volume-text');
    const actions = el('div', 'volume-actions');
    actions.append(actionButton('Show in Finder', 'btn sm', () => send({ type: 'reveal', path: v.path })));
    if (v.ejectable) {
      actions.append(actionButton('Eject', 'btn sm', async () => {
        const result = await send({ type: 'eject', path: v.path });
        toast(result.message, result.ok ? 'good' : 'critical');
      }));
    }
    foot.append(text, actions);
    item.append(driveIcon(kind), name, pct, meta, meter, foot);
    item._refs = { pct, meter, text };
    return item;
  }

  function updateVolume(item, v) {
    if (!item || !item._refs) return;
    const fraction = v.total ? v.used / v.total : 0;
    item._refs.pct.textContent = Math.round(fraction * 100) + '%';
    item._refs.pct.append(el('small', null, fraction >= 0.9 ? 'almost full' : 'used'));
    setMeter(item._refs.meter, fraction);
    item._refs.text.textContent = `${fmt.storage(v.used)} used of ${fmt.storage(v.total)} · ${fmt.storage(v.free)} free`
      + (v.purgeable ? ` (includes ${fmt.storage(v.purgeable)} macOS can clear on its own)` : '')
      + (v.readOnly ? ' · read-only' : '');
  }

  // ---------------------------------------------------------------- processes
  const rowsByKey = new Map();

  function renderProcesses() {
    const procs = state.procs;
    if (!procs) return;
    $('procs-sub').textContent = `${procs.count} of your processes, grouped by app. System processes need admin rights to read, so they aren't listed.`;
    const sorted = [...procs.rows].sort(state.sort === 'cpu'
      ? (a, b) => b.cpu - a.cpu || b.memory - a.memory
      : (a, b) => b.memory - a.memory);
    const maxMemory = Math.max(1, ...sorted.map((r) => r.memory));
    const body = $('procs-body');
    const live = new Set();
    sorted.forEach((row, index) => {
      let tr = rowsByKey.get(row.key);
      if (!tr) { tr = buildProcessRow(row); rowsByKey.set(row.key, tr); }
      updateProcessRow(tr, row, maxMemory);
      live.add(row.key);
      if (body.children[index] !== tr) body.insertBefore(tr, body.children[index] || null);
    });
    for (const [key, tr] of rowsByKey) {
      if (!live.has(key)) { tr.remove(); rowsByKey.delete(key); }
    }
  }

  function buildProcessRow(row) {
    const tr = el('tr');
    const nameCell = el('td');
    const name = el('div', 'p-name');
    const picture = row.app && state.icons.has(row.app) ? el('img', 'p-icon') : el('span', 'p-glyph', row.kind === 'app' ? 'APP' : '>_');
    if (picture.tagName === 'IMG') { picture.src = state.icons.get(row.app); picture.alt = ''; }
    const text = el('div', 'p-text');
    const title = el('span', 'p-title', row.name);
    title.title = row.name;
    const detail = el('span', 'p-detail');
    text.append(title, detail);
    name.append(picture, text);
    nameCell.append(name);

    const memCell = el('td');
    const mem = el('div', 'p-mem');
    const bar = el('span', 'p-bar');
    bar.append(el('span'));
    const memValue = el('span', 'num');
    mem.append(bar, memValue);
    memCell.append(mem);

    const cpuCell = el('td', 'num');

    const actionCell = el('td');
    const actions = el('div', 'p-actions');
    if (row.protected) {
      const lock = el('span', 'p-lock');
      lock.append(icon('lock'), el('span', null, 'Protected'));
      lock.title = row.protected;
      actions.append(lock);
    } else {
      actions.append(
        actionButton('Quit', 'btn sm', () => quit(tr._row, false)),
        actionButton('Force quit', 'btn sm danger', () => quit(tr._row, true)),
      );
    }
    actionCell.append(actions);
    tr.append(nameCell, memCell, cpuCell, actionCell);
    tr._refs = { picture, detail, bar, memValue, cpuCell };
    return tr;
  }

  function updateProcessRow(tr, row, maxMemory) {
    tr._row = row;
    const refs = tr._refs;
    const detail = row.kind === 'app'
      ? (row.count > 1 ? `${row.count} processes` : 'app')
      : (row.detail || '');
    refs.detail.textContent = detail;
    refs.detail.title = detail;
    if (row.app && state.icons.has(row.app) && refs.picture.tagName !== 'IMG') {
      const img = el('img', 'p-icon');
      img.src = state.icons.get(row.app);
      img.alt = '';
      refs.picture.replaceWith(img);
      refs.picture = img;
    }
    refs.bar.firstElementChild.style.width = (row.memory / maxMemory * 100).toFixed(1) + '%';
    refs.memValue.textContent = fmt.gib(row.memory);
    refs.cpuCell.textContent = state.procs && state.procs.ready ? fmt.pct(row.cpu) : '—';   // no interval measured yet
  }

  async function quit(row, force) {
    const whole = row.count > 1 ? `, all ${row.count} of its processes` : '';
    const body = force
      ? `${row.name} stops immediately${whole}. Anything unsaved in it is lost.`
      : row.kind === 'app'
        ? `${row.name} quits the way ⌘Q quits it, so it can ask you to save first.`
        : `MacSense sends it a normal quit signal (SIGTERM), so it can shut down cleanly.`;
    const confirmed = await ask({ title: `${force ? 'Force quit' : 'Quit'} ${row.name}?`, body, confirm: force ? 'Force quit' : 'Quit', danger: force });
    if (!confirmed) return;
    const result = await send({ type: 'quit', key: row.key, force });
    toast(result.message, result.ok ? 'good' : 'critical');
  }

  // ---------------------------------------------------------------- talking to the app
  async function send(message) {
    if (!bridge) return { ok: false, message: 'This is a preview, so nothing happened. Actions only work inside MacSense.app.' };
    try {
      const reply = await bridge.postMessage(message);
      return reply || { ok: false, message: 'MacSense sent no reply.' };
    } catch (error) {
      return { ok: false, message: String((error && error.message) || error) };
    }
  }

  function actionButton(label, className, handler) {
    const button = el('button', className, label);
    button.type = 'button';
    button.addEventListener('click', async () => {
      button.disabled = true;
      try { await handler(); } finally { button.disabled = false; }
    });
    return button;
  }

  function ask({ title, body, confirm, danger }) {
    const dialog = $('confirm');
    $('confirm-title').textContent = title;
    $('confirm-body').textContent = body;
    const ok = $('confirm-ok');
    const cancel = $('confirm-cancel');
    ok.textContent = confirm;
    ok.className = 'btn primary' + (danger ? ' danger' : '');
    return new Promise((resolve) => {
      const finish = (value) => { dialog.close(); resolve(value); };
      ok.onclick = () => finish(true);
      cancel.onclick = () => finish(false);
      dialog.oncancel = (e) => { e.preventDefault(); finish(false); };
      dialog.showModal();
      (danger ? cancel : ok).focus();   // a destructive choice never has the default focus
    });
  }

  let toastTimer = 0;
  function toast(message, tone) {
    if (!message) return;
    const node = $('toast');
    node.replaceChildren(icon(tone === 'good' ? 'good' : 'critical'), el('span', null, message));
    node.className = 'toast show tone-' + (tone || 'good');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.className = 'toast'; }, 5000);
  }

  // ---------------------------------------------------------------- IT scan
  const IT_WORDS = { good: 'OK', warning: 'Check', critical: 'Needs attention', info: 'Info', locked: 'Admin needed' };
  const IT_ICONS = { good: 'good', warning: 'warning', critical: 'critical', info: 'info', locked: 'lock' };

  function itStatus(status) {
    const chip = el('span', 'status tone-' + status);
    chip.append(icon(IT_ICONS[status]), el('span', null, IT_WORDS[status] || status));
    return chip;
  }

  function setScanBusy(busy, text) {
    $('it-loading').hidden = !busy;
    if (text) $('it-loading-text').textContent = text;
    for (const id of ['it-pdf', 'it-json', 'it-email', 'run-scan']) $(id).disabled = busy || (id !== 'run-scan' && !state.itReport);
  }

  async function runItScan(kind) {
    const dialog = $('it-report');
    if (!dialog.open) dialog.showModal();
    if (kind === 'itScan') { $('it-sections').replaceChildren(); $('it-summary').replaceChildren(); state.itReport = null; }
    setScanBusy(true, kind === 'itUnlock'
      ? 'Waiting for an administrator name and password, then scanning again.'
      : 'Checking hardware, security, restarts and crash reports. This takes about 20 seconds.');
    $('it-sub').textContent = kind === 'itUnlock' ? 'Unlocking crash reports…' : 'Scanning this Mac…';
    const result = await send({ type: kind });
    if (result.ok && result.report) state.itReport = result.report;
    setScanBusy(false);
    if (state.itReport) renderItReport(state.itReport);
    else $('it-sub').textContent = result.message || 'The scan did not finish.';
    if (result.message) toast(result.message, result.ok ? 'good' : 'critical');
  }

  function renderItReport(report) {
    const when = new Date(report.generated).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
    $('it-sub').textContent = `${report.computer} · ${report.model} · serial ${report.serial} · scanned ${when}`;
    const s = report.summary;
    const counts = [['critical', s.critical, 'need attention'], ['warning', s.warning, 'to check'], ['good', s.good, 'OK']];
    if (s.locked) counts.push(['locked', s.locked, 'need an admin password']);
    $('it-summary').replaceChildren(...counts.map(([status, count, label]) => {
      const chip = el('span', 'rd-count tone-' + status);
      chip.append(icon(IT_ICONS[status]), el('strong', null, String(count)), el('span', null, label));
      return chip;
    }));
    $('it-sections').replaceChildren(...report.sections.map((section) => {
      const block = el('section', 'rd-section');
      block.append(el('h3', null, section.title), ...section.items.map((item) => {
        const row = el('div', 'rd-row ' + item.status);
        const body = el('div');
        body.append(el('div', 'rd-value', item.value));
        if (item.detail) body.append(el('div', 'rd-detail', item.detail));
        if (item.fix) body.append(el('div', 'rd-fix', item.fix));
        if (item.status === 'locked') {
          body.append(actionButton('Unlock with admin password', 'btn sm primary rd-unlock', () => runItScan('itUnlock')));
        }
        row.append(itStatus(item.status), el('div', 'rd-title', item.title), body);
        return row;
      }));
      return block;
    }));
  }

  // ---------------------------------------------------------------- liveness: say when data stops, never pretend
  function updateLive() {
    let tone = 'good', label = 'Live';
    if (!state.lastArrival) {
      tone = 'wait';
      label = bridge ? 'Starting…' : 'Preview';
    } else {
      const age = performance.now() - state.lastArrival;
      if (age > 3500) { tone = 'warning'; label = `No data for ${Math.round(age / 1000)} s`; }
      else if (state.paused) { tone = 'paused'; label = 'Charts paused'; }
    }
    $('live').className = 'live live-' + tone;
    $('live-text').textContent = label;
  }

  function updateUptime() {
    if (state.info && state.info.bootTime) $('uptime').textContent = 'Up ' + fmt.duration(Date.now() - state.info.bootTime);
  }

  // ---------------------------------------------------------------- controls
  function wireControls() {
    for (const button of document.querySelectorAll('[data-range]')) {
      button.addEventListener('click', () => {
        state.range = Number(button.dataset.range);
        for (const b of document.querySelectorAll('[data-range]')) b.setAttribute('aria-checked', String(b === button));
        $('controls-note').textContent = `Charts show ${RANGE_TEXT[state.range]}, updated every second.`;
        for (const chart of Object.values(charts)) chart.setData(state.history, state.range * 1000);
        if (state.last) renderNetwork(state.last);
        window.MSCharts.requestFrame(true);
      });
    }
    $('pause').addEventListener('click', () => {
      state.paused = !state.paused;
      Clock.freeze(state.paused);
      $('pause').setAttribute('aria-pressed', String(state.paused));
      $('pause').textContent = state.paused ? 'Resume charts' : 'Pause charts';
      updateLive();
    });
    for (const button of document.querySelectorAll('[data-table-for]')) {
      button.addEventListener('click', () => {
        const chart = charts[button.dataset.tableFor];
        const on = button.getAttribute('aria-pressed') !== 'true';
        chart.showTable(on);
        button.setAttribute('aria-pressed', String(on));
        button.textContent = on ? 'Chart' : 'Table';
      });
    }
    for (const button of document.querySelectorAll('[data-sort]')) {
      button.addEventListener('click', () => {
        state.sort = button.dataset.sort;
        for (const b of document.querySelectorAll('[data-sort]')) b.setAttribute('aria-checked', String(b === button));
        renderProcesses();
      });
    }
    $('run-scan').addEventListener('click', () => runItScan('itScan'));
    $('it-close').addEventListener('click', () => $('it-report').close());
    for (const [id, type] of [['it-pdf', 'itSavePDF'], ['it-json', 'itSaveJSON'], ['it-email', 'itEmail']]) {
      $(id).addEventListener('click', async () => {
        const result = await send({ type });
        if (result.message) toast(result.message, result.ok ? 'good' : 'critical');
      });
    }
    $('open-storage').addEventListener('click', () => send({ type: 'storageSettings' }).then((r) => r.ok || toast(r.message, 'critical')));
    $('open-am').addEventListener('click', () => send({ type: 'activityMonitor' }).then((r) => r.ok || toast(r.message, 'critical')));
    // Right-click is for copying a process name or path, nothing else.
    document.addEventListener('contextmenu', (e) => { if (!e.target.closest('.p-title, .p-detail')) e.preventDefault(); });
  }

  buildCharts();
  buildSparks();
  wireControls();
  if (!bridge) $('preview').hidden = false;
  setInterval(updateLive, 1000);
  setInterval(updateUptime, 30000);
  updateLive();

  window.MacSense = { init, onSample };
})();
