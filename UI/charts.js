/* MacSense charts: canvas time series with a crosshair tooltip and a table-view twin.
   One mark spec everywhere: 2px lines, a light area wash, hairline grid, 8px end markers with a
   2px surface ring, and labels in text colours, never in series colours. */
(function () {
  'use strict';

  const root = getComputedStyle(document.documentElement);
  const token = (name) => root.getPropertyValue(name).trim();
  const T = {
    surface: token('--surface'), ink: token('--ink'), ink2: token('--ink-2'), ink3: token('--ink-3'),
    grid: token('--grid'), axis: token('--axis'),
  };
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const FONT = '11px system-ui, -apple-system, sans-serif';
  const FONT_STRONG = '600 11.5px system-ui, -apple-system, sans-serif';
  const EASE_MS = 360;
  const FRAME_MS = 1000 / 24;   // the glide runs at 24 fps: smooth to the eye, a fraction of 60 fps's cost
  const GiB = 1024 ** 3;

  function withAlpha(hex, alpha) {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;   // never innerHTML: names come from other programs
    return node;
  }

  // ------------------------------------------------------------------ formatting
  const whole = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  const fmt = {
    pct(v) {
      if (v == null) return '—';
      if (v < 0.05) return '0%';
      return (v >= 10 ? Math.round(v) : v.toFixed(1)) + '%';
    },
    gib(bytes) {
      if (bytes == null) return '—';
      const g = bytes / GiB;
      return (g >= 10 ? g.toFixed(1) : g.toFixed(2)) + ' GB';
    },
    // Storage in decimal units, like Finder (1 GB = 1,000,000,000 bytes).
    storage(bytes) {
      if (bytes == null) return '—';
      if (bytes >= 1e12) return (bytes / 1e12).toFixed(2) + ' TB';
      if (bytes >= 1e9) return (bytes / 1e9 >= 100 ? Math.round(bytes / 1e9) : (bytes / 1e9).toFixed(1)) + ' GB';
      if (bytes >= 1e6) return Math.round(bytes / 1e6) + ' MB';
      return Math.max(0, Math.round(bytes / 1e3)) + ' KB';
    },
    // Broadband speeds in bits per second.
    mbps(v) {
      if (v == null) return '—';
      if (v >= 100) return Math.round(v) + ' Mbps';
      if (v >= 10) return v.toFixed(1) + ' Mbps';
      if (v >= 1) return v.toFixed(2) + ' Mbps';
      return Math.round(v * 1000) + ' kbps';
    },
    temp(c) { return c == null ? '—' : Math.round(c) + '°C'; },
    rpm(r) { return r == null ? '—' : whole.format(Math.round(r)) + ' rpm'; },
    int(v) { return v == null ? '—' : whole.format(Math.round(v)); },
    clock(t) { return new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', second: '2-digit' }); },
    ago(ms) {
      const s = Math.max(0, Math.round(ms / 1000));
      if (s < 2) return 'now';
      if (s < 60) return s + ' s ago';
      const m = Math.floor(s / 60), r = s % 60;
      return m + ' min' + (r ? ' ' + r + ' s' : '') + ' ago';
    },
    duration(ms) {
      let s = Math.floor(ms / 1000);
      const d = Math.floor(s / 86400); s -= d * 86400;
      const h = Math.floor(s / 3600); s -= h * 3600;
      const m = Math.floor(s / 60);
      if (d) return `${d} d ${h} h`;
      if (h) return `${h} h ${m} min`;
      return `${m} min`;
    },
  };

  // ------------------------------------------------------------------ one clock for every chart
  // The right edge of every chart eases from the previous sample to the newest one, so the
  // lines glide instead of jumping a step each second. Paused charts hold their frame.
  const Clock = {
    last: 0, interval: 1000, animStart: 0, frozenAt: null,
    push(t) {
      if (this.last) this.interval = Math.min(3000, Math.max(250, t - this.last));
      this.last = t;
      this.animStart = performance.now();
      requestFrame(true);
    },
    now() {
      if (this.frozenAt != null) return this.frozenAt;
      if (reducedMotion || !this.last) return this.last;
      const p = Math.min(1, (performance.now() - this.animStart) / EASE_MS);
      return this.last - Math.pow(1 - p, 3) * this.interval;
    },
    animating() { return this.frozenAt == null && !reducedMotion && performance.now() - this.animStart < EASE_MS; },
    freeze(on) { this.frozenAt = on ? this.now() : null; requestFrame(true); },
  };

  const charts = new Set();
  const dirty = new Set();
  let frame = 0;
  let nextGlideFrame = 0;
  let drawEverything = false;
  function requestFrame(all, chart) {
    if (all) drawEverything = true;
    else if (chart) dirty.add(chart);
    if (!frame) frame = requestAnimationFrame(renderFrame);
  }
  function renderFrame() {
    frame = 0;
    const animating = Clock.animating();
    for (const chart of drawEverything || animating ? charts : dirty) chart.draw();
    dirty.clear();
    drawEverything = false;
    if (animating && !nextGlideFrame) {
      nextGlideFrame = setTimeout(() => { nextGlideFrame = 0; requestFrame(true); }, FRAME_MS);
    }
  }

  // ------------------------------------------------------------------ scale helpers
  /** 0 … a round number at or above max, in 1/2/2.5/5 steps: 0 25 50 75 100, or 0 5 10 15. */
  function niceTicks(max, count) {
    if (!(max > 0)) max = 1;
    const raw = max / count;
    const magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
    const n = raw / magnitude;
    const step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * magnitude;
    const last = Math.ceil(max / step - 1e-9);
    const ticks = [];
    for (let i = 0; i <= last; i++) ticks.push(+(i * step).toPrecision(12));
    return ticks;
  }
  function lowerBound(points, t) {
    let a = 0, b = points.length;
    while (a < b) { const m = (a + b) >> 1; if (points[m].t < t) a = m + 1; else b = m; }
    return a;
  }
  function nearest(points, t, lo, hi) {
    if (hi <= lo) return null;
    let i = Math.min(hi - 1, lowerBound(points, t));
    if (i > lo && Math.abs(points[i - 1].t - t) < Math.abs(points[i].t - t)) i--;
    return Math.max(lo, i);
  }
  function dot(ctx, x, y, color) {
    ctx.beginPath(); ctx.arc(x, y, 6, 0, Math.PI * 2); ctx.fillStyle = T.surface; ctx.fill();   // 2px surface ring
    ctx.beginPath(); ctx.arc(x, y, 4, 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill();
  }

  // ------------------------------------------------------------------ tooltip (shared)
  const Tooltip = {
    node: null, owner: null,
    show(owner, x, y, children) {
      const node = this.node || (this.node = document.getElementById('tooltip'));
      this.owner = owner;
      node.replaceChildren(...children);
      node.hidden = false;
      const box = node.getBoundingClientRect();
      let left = x + 16, top = y + 14;
      if (left + box.width > window.innerWidth - 8) left = x - box.width - 16;
      if (top + box.height > window.innerHeight - 8) top = y - box.height - 14;
      node.style.left = Math.max(8, left) + 'px';
      node.style.top = Math.max(8, top) + 'px';
    },
    hide(owner) {
      if (this.node && (!owner || this.owner === owner)) { this.node.hidden = true; this.owner = null; }
    },
  };
  function tooltipRow(color, value, label) {
    const row = el('div', 'tt-row');
    const key = el('span', 'key-line');
    if (color) key.style.background = color;
    row.append(key, el('span', 'tt-value', value), el('span', 'tt-label', label));
    return row;
  }

  // ------------------------------------------------------------------ the time-series chart
  class TimeChart {
    constructor(host, options) {
      this.host = host;
      this.o = Object.assign({
        height: 180, yMax: null, minTop: 1, stacked: false, area: true, unit: '', band: null, legend: null,
        format: String, axis: null, totalLabel: null, ariaLabel: '',
      }, options);
      this.series = this.o.series || [];
      this.points = [];
      this.range = 60000;
      this.hover = null;
      this.canvas = document.createElement('canvas');
      this.canvas.tabIndex = 0;
      this.canvas.setAttribute('role', 'img');
      this.canvas.setAttribute('aria-label', this.o.ariaLabel + '. Use the arrow keys to read values.');
      this.table = el('div', 'chart-table');
      this.table.hidden = true;
      host.append(this.canvas, this.table);
      this.ctx = this.canvas.getContext('2d');

      this.canvas.addEventListener('pointermove', (e) => {
        this.hover = { x: e.offsetX, cx: e.clientX, cy: e.clientY };
        requestFrame(false, this);
      });
      this.canvas.addEventListener('pointerleave', () => { this.hover = null; Tooltip.hide(this); requestFrame(false, this); });
      this.canvas.addEventListener('keydown', (e) => this.onKey(e));
      this.canvas.addEventListener('blur', () => {
        if (this.hover && this.hover.index != null) { this.hover = null; Tooltip.hide(this); requestFrame(false, this); }
      });
      new ResizeObserver(() => this.resize()).observe(host);
      // A chart scrolled out of view doesn't draw; it catches up the moment it's visible again.
      this.visible = true;
      new IntersectionObserver(([entry]) => {
        this.visible = entry.isIntersecting;
        if (this.visible) requestFrame(false, this);
      }).observe(host);
      if (this.o.legend) this.renderLegend();
      charts.add(this);
    }

    setSeries(series) {
      this.series = series;
      if (this.o.legend) this.renderLegend();
      requestFrame(false, this);
    }

    setData(points, rangeMs) {
      this.points = points;
      this.range = rangeMs;
      if (!this.table.hidden) this.renderTable();
    }

    showTable(on) {
      this.table.hidden = !on;
      this.canvas.hidden = on;
      if (on) this.renderTable(); else requestFrame(false, this);
    }

    renderLegend() {
      // A single series needs no legend: the chart's title already names it.
      const items = this.series.length < 2 ? [] : this.series.map((s) => {
        const item = el('span', 'legend-item');
        const swatch = el('span', 'swatch');
        swatch.style.background = s.color;
        item.append(swatch, el('span', null, s.label));
        return item;
      });
      this.o.legend.replaceChildren(...items);
    }

    resize() {
      const w = Math.floor(this.host.clientWidth);
      if (!w) return;
      const dpr = window.devicePixelRatio || 1;
      this.w = w;
      this.h = this.o.height;
      this.canvas.width = Math.round(w * dpr);
      this.canvas.height = Math.round(this.h * dpr);
      this.canvas.style.width = w + 'px';
      this.canvas.style.height = this.h + 'px';
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      this.draw();
    }

    value(point, s) {
      const v = point[s.key];
      return typeof v === 'number' && isFinite(v) ? v : null;
    }

    draw() {
      const { ctx, w, h } = this;
      if (!w || this.canvas.hidden || !this.visible || document.hidden) return;
      ctx.clearRect(0, 0, w, h);

      const now = Clock.now();
      const t0 = now - this.range;
      const bandH = this.o.band ? 10 : 0;
      const top = this.o.unit ? 20 : 10;
      const plot = { x: 46, y: top, w: w - 46 - 78, h: h - top - 24 - bandH };
      if (plot.w < 60 || plot.h < 24) return;

      const pts = this.points;
      const lo = Math.max(0, lowerBound(pts, t0) - 1);
      const hi = pts.length;

      // ---- y scale
      let maxV = 0;
      for (let i = lo; i < hi; i++) {
        if (this.o.stacked) {
          let sum = 0;
          for (const s of this.series) sum += this.value(pts[i], s) || 0;
          maxV = Math.max(maxV, sum);
        } else {
          for (const s of this.series) { const v = this.value(pts[i], s); if (v != null && v > maxV) maxV = v; }
        }
      }
      let yTop = this.o.yMax;
      if (yTop == null) {
        const target = niceTicks(Math.max(this.o.minTop, maxV * 1.1), 4).pop();
        // Ease toward a new scale, so a spike leaving the window doesn't make the chart jump.
        if (this.shownTop == null || reducedMotion || Math.abs(this.shownTop - target) <= target * 0.005) {
          this.shownTop = target;
        } else {
          this.shownTop += (target - this.shownTop) * 0.35;
          requestFrame(false, this);
        }
        yTop = this.shownTop;
      }
      const ticks = niceTicks(yTop, 4).filter((v) => v <= yTop * (1 + 1e-9));
      const X = (t) => plot.x + ((t - t0) / this.range) * plot.w;
      const Y = (v) => plot.y + plot.h - (Math.min(v, yTop) / yTop) * plot.h;

      // ---- grid, y labels, unit
      ctx.font = FONT;
      ctx.lineWidth = 1;
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      for (const v of ticks) {
        const yy = Math.round(Y(v)) + 0.5;
        ctx.strokeStyle = v === 0 ? T.axis : T.grid;
        ctx.beginPath(); ctx.moveTo(plot.x, yy); ctx.lineTo(plot.x + plot.w, yy); ctx.stroke();
        ctx.fillStyle = T.ink3;
        ctx.fillText((this.o.axis || this.o.format)(v, yTop), plot.x - 8, yy);
      }
      const unit = typeof this.o.unit === 'function' ? this.o.unit(yTop) : this.o.unit;
      if (unit) {
        ctx.textAlign = 'left';
        ctx.textBaseline = 'top';
        ctx.fillText(unit, 6, 0);
      }

      // ---- x labels: fixed relative positions; the data scrolls underneath them
      const step = this.range <= 60000 ? 15000 : this.range <= 300000 ? 60000 : 300000;
      ctx.textBaseline = 'top';
      ctx.fillStyle = T.ink3;
      const labelY = plot.y + plot.h + bandH + 7;
      for (let ago = 0; ago <= this.range + 1; ago += step) {
        const xx = plot.x + plot.w - (ago / this.range) * plot.w;
        ctx.textAlign = ago === 0 ? 'right' : ago >= this.range ? 'left' : 'center';
        ctx.fillText(ago === 0 ? 'now' : ago < 60000 ? `−${ago / 1000}s` : `−${ago / 60000} min`, xx, labelY);
      }

      if (!pts.length) return;

      // ---- series
      ctx.save();
      ctx.beginPath();
      ctx.rect(plot.x, plot.y - 3, plot.w, plot.h + 6);
      ctx.clip();
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      const maxGap = Math.max(3500, Clock.interval * 3.5);   // don't draw across sleep or a stall
      const base = new Float64Array(hi - lo);
      for (const s of this.series) {
        const upper = new Float64Array(hi - lo);
        const valid = new Uint8Array(hi - lo);
        for (let i = lo; i < hi; i++) {
          const v = this.value(pts[i], s);
          valid[i - lo] = v == null ? 0 : 1;
          upper[i - lo] = (this.o.stacked ? base[i - lo] : 0) + (v || 0);
        }
        this.runs(pts, lo, hi, valid, maxGap, (a, b) => {
          if (this.o.area) {
            ctx.beginPath();
            for (let i = a; i <= b; i++) {
              const xx = X(pts[i].t), yy = Y(upper[i - lo]);
              if (i === a) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy);
            }
            for (let i = b; i >= a; i--) ctx.lineTo(X(pts[i].t), Y(this.o.stacked ? base[i - lo] : 0));
            ctx.closePath();
            ctx.fillStyle = withAlpha(s.color, this.o.stacked ? 0.2 : 0.12);
            ctx.fill();
          }
          ctx.beginPath();
          for (let i = a; i <= b; i++) {
            const xx = X(pts[i].t), yy = Y(upper[i - lo]);
            if (i === a) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy);
          }
          ctx.strokeStyle = s.color;
          ctx.lineWidth = 2;
          ctx.stroke();
        });
        if (this.o.stacked) base.set(upper);
      }
      ctx.restore();

      // ---- status band (memory pressure)
      if (this.o.band) {
        const band = this.o.band;
        const yb = plot.y + plot.h + 4;
        for (let i = lo; i < hi; i++) {
          const v = pts[i][band.key];
          if (v == null) continue;
          const x1 = Math.max(plot.x, X(pts[i].t));
          const x2 = Math.min(plot.x + plot.w, i + 1 < hi ? X(pts[i + 1].t) : X(now));
          if (x2 <= x1) continue;
          ctx.fillStyle = band.colors[v] || T.axis;
          ctx.fillRect(x1, yb, x2 - x1, 4);
        }
      }

      // ---- end markers glide along the right edge; values sit beside them. A stacked chart
      // labels only its total, at the top, so no label sits at a height it doesn't describe.
      const last = pts[hi - 1];
      const ends = [];
      let total = 0;
      for (const s of this.series) {
        const v = this.value(last, s);
        if (v == null) continue;
        total += v;
        const edgeValue = this.valueAt(now, s);
        if (edgeValue == null) continue;
        ends.push({ s, v, y: Y(edgeValue) });
      }
      for (const end of ends) dot(ctx, plot.x + plot.w, end.y, end.s.color);
      const labelled = this.o.stacked && ends.length ? [{ ...ends[ends.length - 1], v: total }] : ends;
      const sorted = labelled.slice().sort((a, b) => a.y - b.y);
      const collide = sorted.some((end, i) => i > 0 && end.y - sorted[i - 1].y < 15);
      if (!collide) {
        ctx.font = FONT_STRONG;
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.fillStyle = T.ink;
        for (const end of labelled) {
          ctx.fillText(this.o.format(end.v), plot.x + plot.w + 12, Math.min(plot.y + plot.h - 6, Math.max(plot.y + 6, end.y)));
        }
      }

      // ---- crosshair + tooltip
      if (this.hover) this.drawHover(plot, X, Y, t0, lo, hi);
    }

    /** The series value (stacked: the cumulative top) at time t, interpolated between samples. */
    valueAt(t, series) {
      const pts = this.points;
      const i = lowerBound(pts, t);
      const at = (p) => {
        let total = 0;
        for (const s of this.series) {
          const v = this.value(p, s);
          if (s === series) return v == null ? null : (this.o.stacked ? total + v : v);
          total += v || 0;
        }
        return null;
      };
      if (i >= pts.length) return at(pts[pts.length - 1]);
      if (i === 0) return at(pts[0]);
      const a = pts[i - 1], b = pts[i];
      const va = at(a), vb = at(b);
      if (va == null || vb == null) return vb ?? va;
      const f = (t - a.t) / Math.max(1, b.t - a.t);
      return va + (vb - va) * f;
    }

    drawHover(plot, X, Y, t0, lo, hi) {
      const { ctx } = this;
      const pts = this.points;
      let index;
      if (this.hover.index != null) index = Math.min(hi - 1, Math.max(lo, this.hover.index));
      else index = nearest(pts, t0 + ((this.hover.x - plot.x) / plot.w) * this.range, lo, hi);
      if (index == null) { Tooltip.hide(this); return; }
      const p = pts[index];
      const xx = Math.round(X(p.t)) + 0.5;
      // Only snap to a sample near the pointer; over a stretch with no data there's nothing to read.
      const tooFar = this.hover.index == null && Math.abs(xx - this.hover.x) > Math.max(24, (2.5 * Clock.interval / this.range) * plot.w);
      if (tooFar || xx < plot.x || xx > plot.x + plot.w + 1) { Tooltip.hide(this); return; }

      ctx.strokeStyle = withAlpha(T.ink, 0.4);
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(xx, plot.y); ctx.lineTo(xx, plot.y + plot.h); ctx.stroke();

      const rows = [];
      let total = 0;
      for (const s of this.series) {
        const v = this.value(p, s);
        if (v == null) { rows.push(tooltipRow(s.color, '—', s.label)); continue; }
        total += v;
        dot(ctx, xx, Y(this.o.stacked ? total : v), s.color);
        rows.push(tooltipRow(s.color, this.o.format(v), s.label));
      }
      if (this.o.stacked) rows.reverse();   // top band first, matching the picture
      if (this.o.stacked && this.o.totalLabel) rows.push(tooltipRow(null, this.o.format(total), this.o.totalLabel));
      if (this.o.band && p[this.o.band.key] != null) {
        const v = p[this.o.band.key];
        rows.push(tooltipRow(this.o.band.colors[v], this.o.band.names[v] || '—', this.o.band.label));
      }
      const rect = this.canvas.getBoundingClientRect();
      const cx = this.hover.cx != null ? this.hover.cx : rect.left + xx;
      const cy = this.hover.cy != null ? this.hover.cy : rect.top + plot.y + 8;
      Tooltip.show(this, cx, cy, [el('div', 'tt-time', `${fmt.clock(p.t)} · ${fmt.ago(Clock.last - p.t)}`), ...rows]);
    }

    /** Calls fn(first, last) for each unbroken run of valid points. */
    runs(pts, lo, hi, valid, maxGap, fn) {
      let start = -1;
      for (let i = lo; i < hi; i++) {
        const ok = valid[i - lo] === 1;
        if (start >= 0 && (!ok || pts[i].t - pts[i - 1].t > maxGap)) { fn(start, i - 1); start = -1; }
        if (ok && start < 0) start = i;
      }
      if (start >= 0) fn(start, hi - 1);
    }

    onKey(e) {
      const n = this.points.length;
      if (!n) return;
      let i = this.hover && this.hover.index != null ? this.hover.index : n - 1;
      if (e.key === 'ArrowLeft') i = Math.max(0, i - 1);
      else if (e.key === 'ArrowRight') i = Math.min(n - 1, i + 1);
      else if (e.key === 'Home') i = lowerBound(this.points, Clock.now() - this.range);
      else if (e.key === 'End') i = n - 1;
      else if (e.key === 'Escape') { this.hover = null; Tooltip.hide(this); requestFrame(false, this); return; }
      else return;
      e.preventDefault();
      this.hover = { index: i };
      requestFrame(false, this);
    }

    /** The table twin: the same series at even steps back from now. */
    renderTable() {
      const step = this.range <= 60000 ? 5000 : this.range <= 300000 ? 30000 : 60000;
      const picked = [];
      let next = Infinity;
      for (let i = this.points.length - 1; i >= 0 && picked.length < 16; i--) {
        const p = this.points[i];
        if (p.t > next) continue;
        picked.push(p);
        next = p.t - step + 400;
      }
      const head = el('tr');
      head.append(el('th', null, 'Time'), ...this.series.map((s) => el('th', null, s.label)));
      if (this.o.band) head.append(el('th', null, this.o.band.label));
      const body = el('tbody');
      for (const p of picked) {
        const row = el('tr');
        row.append(el('td', null, fmt.clock(p.t)), ...this.series.map((s) => {
          const v = this.value(p, s);
          return el('td', null, v == null ? '—' : this.o.format(v));
        }));
        if (this.o.band) row.append(el('td', null, this.o.band.names[p[this.o.band.key]] || '—'));
        body.append(row);
      }
      const thead = el('thead');
      thead.append(head);
      const table = el('table', 'data');
      table.append(thead, body);
      this.table.replaceChildren(table);
    }
  }

  // ------------------------------------------------------------------ sparkline for the summary tiles
  // A trend in the de-emphasis grey, with only the current point in the metric's colour.
  class Sparkline {
    constructor(canvas, color) {
      this.canvas = canvas;
      this.color = color;
      this.ctx = canvas.getContext('2d');
    }

    draw(values, max) {
      const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
      if (!w || !h) return;
      const dpr = window.devicePixelRatio || 1;
      if (this.canvas.width !== Math.round(w * dpr)) {
        this.canvas.width = Math.round(w * dpr);
        this.canvas.height = Math.round(h * dpr);
      }
      const ctx = this.ctx;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      if (values.length < 2) return;
      const present = values.filter((v) => v != null);
      if (!present.length) return;
      const top = max || Math.max(1e-9, ...present) * 1.15;
      const n = values.length;
      const X = (i) => 3 + (i / (n - 1)) * (w - 10);
      const Y = (v) => h - 5 - (Math.min(v, top) / top) * (h - 10);
      ctx.beginPath();
      let drawing = false;
      values.forEach((v, i) => {
        if (v == null) { drawing = false; return; }
        if (drawing) ctx.lineTo(X(i), Y(v)); else { ctx.moveTo(X(i), Y(v)); drawing = true; }
      });
      ctx.strokeStyle = T.ink3;
      ctx.lineWidth = 1.5;
      ctx.lineJoin = 'round';
      ctx.stroke();
      const lastValue = values[n - 1];
      if (lastValue != null) {
        ctx.beginPath(); ctx.arc(X(n - 1), Y(lastValue), 5, 0, Math.PI * 2); ctx.fillStyle = T.surface; ctx.fill();
        ctx.beginPath(); ctx.arc(X(n - 1), Y(lastValue), 3, 0, Math.PI * 2); ctx.fillStyle = this.color; ctx.fill();
      }
    }
  }

  // Minimised or hidden window: nothing draws. Coming back redraws everything once.
  document.addEventListener('visibilitychange', () => { if (!document.hidden) requestFrame(true); });

  window.MSCharts = { TimeChart, Sparkline, Clock, Tooltip, tooltipRow, fmt, el, withAlpha, requestFrame };
})();
