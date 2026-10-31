/* CODM Optimizer - WebUI
 *
 * Talks to webroot/actions.sh through the KernelSU / APatch WebUI bridge
 * (`ksu.exec`). No network, no framework, no external assets: the whole
 * interface is these three files.
 */

'use strict';

// --------------------------------------------------------------- bridge --
const ACTION_PATHS = [
  '/data/adb/modules/codm-optimizer/webroot/actions.sh',
  '/data/adb/modules_update/codm-optimizer/webroot/actions.sh',
];

let actionsPath = null;
let bridgeOK = false;
let busy = false;

function bridge() {
  return (typeof ksu !== 'undefined' && ksu && typeof ksu.exec === 'function') ? ksu : null;
}

async function exec(cmd) {
  const k = bridge();
  if (!k) throw new Error('no WebUI bridge');
  let out;
  try {
    out = await k.exec(cmd, JSON.stringify({ cwd: '/' }));
  } catch (e) {
    out = await k.exec(cmd);
  }
  return typeof out === 'string' ? out : (out == null ? '' : String(out));
}

async function resolveActions() {
  const list = ACTION_PATHS.map(p => `'${p}'`).join(' ');
  const out = await exec(`for f in ${list}; do [ -f "$f" ] && { echo "$f"; break; }; done`);
  const first = (out || '').split('\n').map(s => s.trim()).filter(Boolean)[0];
  if (first) actionsPath = first;
  return !!actionsPath;
}

/** Run an actions.sh command and return the parsed result. */
async function run(args) {
  if (DEMO) return demoRun(args);
  if (!actionsPath && !(await resolveActions())) {
    throw new Error('actions.sh not found (is the module installed?)');
  }
  const out = await exec(`sh '${actionsPath}' ${args}`);
  return parse(out);
}

function parse(text) {
  const kv = {};
  const rows = [];
  (text || '').split('\n').forEach(line => {
    if (!line) return;
    if (line.startsWith('row|')) {
      const parts = line.split('|');
      parts.shift();
      const type = parts.shift();
      while (parts.length && parts[parts.length - 1] === '') parts.pop();
      rows.push({ type, f: parts });
    } else {
      const i = line.indexOf('=');
      if (i > 0) kv[line.slice(0, i)] = line.slice(i + 1);
    }
  });
  return { kv, rows };
}

// ----------------------------------------------------------------- util --
const $ = id => document.getElementById(id);

function toast(msg, kind) {
  const t = $('toast');
  t.textContent = msg || '';
  t.className = 'toast show' + (kind ? ' ' + kind : '');
  t.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => {
    t.className = 'toast';
    setTimeout(() => { t.hidden = true; }, 260);
  }, 2600);
}

/** control name (data-key) -> snapshot key, where they differ. */
const CFG_KEY = {
  TEMP_LIMIT_C: 'cfg.temp_limit',
  THERMAL_LIFT_C: 'cfg.thermal_lift',
  POLL_GAME_SEC: 'cfg.poll_game',
  REAPPLY_SEC: 'cfg.reapply',
};
const cfgKey = name => CFG_KEY[name] || ('cfg.' + name.toLowerCase());

const PROFILE_INFO = {
  adaptive: {
    name: 'Adaptive',
    desc: 'Balanced while cool, eases GPU and refresh before the thermal limit.',
    tag: 'recommended',
  },
  balanced: { name: 'Balanced', desc: 'Fixed, moderate ramp and GPU floor.' },
  performance: { name: 'Performance', desc: 'Faster ramp, GPU floor at half the range.' },
  extreme: { name: 'Extreme', desc: 'Maximum ramp and floors. Cooler recommended.' },
  battery: { name: 'Battery', desc: 'Lowest floors, minimal tuning, longest sessions.' },
};

const num = (v, fallback = '—') => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : fallback;
};

function fmtClock(epochSec) {
  const n = num(epochSec, null);
  if (n === null || n <= 0) return '—';
  const d = new Date(n * 1000);
  return d.toLocaleString(undefined, {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

function fmtDuration(min) {
  const m = num(min, null);
  if (m === null) return '—';
  if (m < 60) return `${Math.round(m)} min`;
  return `${Math.floor(m / 60)}h ${String(Math.round(m % 60)).padStart(2, '0')}m`;
}

// ------------------------------------------------------------- snapshot --
const state = {
  ready: false,
  data: null,
  history: [],
  lastGoodAt: 0,
};

async function refresh(silent) {
  if (!bridgeOK) return;
  try {
    const { kv, rows } = await run('snapshot');
    state.data = { kv, rows };
    state.ready = true;
    state.lastGoodAt = Date.now();
    render(kv, rows);
  } catch (e) {
    if (!silent) toast(String(e.message || e), 'err');
    setPill('off', 'offline');
  }
}

// -------------------------------------------------------------- render ---
function setPill(kind, text) {
  const pill = $('statusPill');
  pill.className = 'pill pill-' + kind;
  $('statusText').textContent = text;
}

function renderStatus(kv) {
  const running = kv['engine.running'] === '1';
  const st = kv['engine.state'] || 'unknown';
  const profile = kv['cfg.profile'] || '—';
  const info = PROFILE_INFO[profile] || { name: profile, desc: '' };

  if (!running) setPill('off', 'engine off');
  else if (st === 'hot') setPill('hot', 'cooling');
  else if (st === 'active') setPill('live', 'in game');
  else setPill('live', 'watching');

  const level = kv['thermal.level'] || '';
  $('heroProfile').textContent = info.name;
  let sub = info.desc || '';
  if (profile === 'adaptive' && level) sub = `Adaptive · ${level} step`;
  if (!running) sub = 'Engine stopped — no tuning is applied.';
  $('heroProfileSub').textContent = sub;

  const batt = num(kv['thermal.battery'], null);
  const limit = num(kv['thermal.limit'], 43);
  const gaugeFill = $('gaugeFill');
  const CIRC = 264;
  if (batt !== null) {
    const lo = 25, hi = limit + 3;
    const pct = Math.max(0, Math.min(1, (batt - lo) / (hi - lo)));
    gaugeFill.style.strokeDashoffset = String(CIRC * (1 - pct));
    const colour = batt >= limit ? '#ef4444' : batt >= limit - 5 ? '#f59e0b' : '#22d3a7';
    gaugeFill.style.stroke = colour;
    $('gaugeValue').textContent = String(Math.round(batt));
    state.history.push(batt);
    if (state.history.length > 42) state.history.shift();
  } else {
    $('gaugeValue').textContent = '—';
    gaugeFill.style.strokeDashoffset = String(CIRC);
  }

  const soc = num(kv['thermal.soc'], null);
  $('socTemp').textContent = soc === null ? '—' : `${Math.round(soc)}°C`;
  const guard = kv['thermal.guard'] || 'ok';
  $('guardState').textContent = guard === 'hot' ? 'holding' : 'ok';
  $('guardState').style.color = guard === 'hot' ? '#f59e0b' : '';
  $('adaptLevel').textContent = kv['cfg.adaptive'] === '1' ? (level || '—') : 'fixed';

  drawSpark($('spark'), state.history, limit);

  const chip = $('engineChip');
  chip.textContent = running ? `on · ${kv['engine.state']}` : 'off';
  chip.className = 'chip ' + (running ? 'ok' : '');

  const installed = (kv['game.installed'] || '').trim();
  $('rowGame').textContent = installed || 'not installed';
  const gs = kv['game.state'] || '';
  $('rowDetect').textContent = {
    foreground: 'in foreground', background: 'in background', none: 'not running',
  }[gs] || gs || '—';
  $('rowPanel').textContent = kv['display.max'] ? `${kv['display.max']} Hz` : '—';
  const shown = v => (!v || v === 'null' ? 'default' : v);
  $('rowRefresh').textContent =
    `${shown(kv['display.min_setting'])} / ${shown(kv['display.peak_setting'])}`;
  const gm = kv['gamemode.report'] || '';
  const gmMode = (gm.match(/current mode:\s*([a-z]+)/) || [])[1];
  $('rowGamemode').textContent = gmMode || (gm ? 'unsupported' : '—');

  const last = kv['session.last'] || '';
  if (last) {
    const p = last.split(/\s+/);
    $('rowSession').textContent = `${fmtDuration(num(p[1], 0) / 60)} · ${p[3] && p[3] !== '?' ? p[3] + '°C peak' : 'no temp'} · ${p.slice(4).join(' ') || ''}`;
  } else {
    $('rowSession').textContent = 'none yet';
  }

  const capCpu = kv['cap.cpu'] === '1';
  $('cpuChip').textContent = capCpu ? 'controllable' : 'not exposed';
  $('cpuChip').className = 'chip ' + (capCpu ? 'ok' : 'bad');

  const capGpu = kv['cap.gpu'] === '1';
  $('gpuChip').textContent = kv['cap.gpu_driver'] || 'unknown';
  $('gpuChip').className = 'chip ' + (capGpu ? 'ok' : 'bad');
  if (capGpu) {
    $('gpuBody').className = '';
    $('gpuBody').innerHTML =
      `<div class="cpu-item">
         <div class="cpu-top"><span>${kv['gpu.cur'] || 0} MHz</span>
         <i>floor ${kv['gpu.min'] || 0} · max ${kv['gpu.max'] || 0} MHz</i></div>
         <div class="bar"><i style="width:${Math.min(100, (num(kv['gpu.cur'], 0) / Math.max(1, num(kv['gpu.max'], 1))) * 100)}%"></i></div>
       </div>`;
  } else {
    $('gpuBody').className = 'empty';
    $('gpuBody').textContent = 'No controllable GPU node — the module leaves the GPU alone.';
  }
}

function renderCpu(rows) {
  const cpuRows = rows.filter(r => r.type === 'cpu');
  const box = $('cpuList');
  if (!cpuRows.length) {
    box.innerHTML = '<p class="empty">No cpufreq interface.</p>';
    return;
  }
  box.innerHTML = cpuRows.map(({ f }) => {
    const [name, gov, cur, min, max] = f;
    const pct = Math.max(0, Math.min(100, (num(cur, 0) / Math.max(1, num(max, 1))) * 100));
    return `<div class="cpu-item">
      <div class="cpu-top"><span>${name} · ${gov || '?'}</span>
      <i>${cur || 0} / ${max || 0} MHz</i></div>
      <div class="bar"><i style="width:${pct}%"></i></div>
    </div>`;
  }).join('');
}

function renderTune(kv) {
  document.querySelectorAll('[data-key]').forEach(el => {
    const key = el.dataset.key;
    if (key === '__denylist') return;
    const v = kv[cfgKey(key)];
    if (v === undefined) return;
    // never fight the user: skip the focused control and any control with a
    // write still in flight (a snapshot can land mid-drag)
    if (document.activeElement === el) return;
    if (el.dataset.pending) return;
    if (el.type === 'checkbox') el.checked = v === '1';
    else el.value = v;
  });

  // slider readouts
  $('tempLimitOut').textContent = `${kv['cfg.temp_limit'] || '—'} °C`;
  $('thermalLiftOut').textContent = `${kv['cfg.thermal_lift'] || 0} °C`;
  $('thermalWarn').hidden = (kv['cfg.thermal_lift'] || '0') === '0';
  $('gpuCoolOut').textContent = `${kv['cfg.adapt_gpu_cool'] || 0} %`;
  $('gpuWarmOut').textContent = `${kv['cfg.adapt_gpu_warm'] || 0} %`;
  $('gpuHotOut').textContent = `${kv['cfg.adapt_gpu_hot'] || 0} %`;
  $('hzHotOut').textContent = `${kv['cfg.adapt_hz_hot'] || 90} Hz`;

  // profiles
  const active = kv['cfg.profile'];
  $('profileList').innerHTML = Object.entries(PROFILE_INFO).map(([id, p]) => `
    <button class="profile${id === active ? ' active' : ''}" data-profile="${id}">
      <b>${p.name}${p.tag ? `<span class="tag">${p.tag}</span>` : ''}</b>
      <span class="tick">✓</span>
      <small>${p.desc}</small>
    </button>`).join('');

  $('gamemodeHint').textContent = kv['gamemode.report'] || '—';

  const canDeny = kv['cap.denylist'] === '1';
  $('denylistRow').hidden = !canDeny;
}

function renderInfo(kv) {
  $('deviceLine').textContent = `${kv['device.model'] || 'device'} · ${kv['device.soc'] || ''}`.trim();
  $('infoModel').textContent = kv['device.model'] || '—';
  $('infoSoc').textContent = kv['device.soc'] || '—';
  $('infoAndroid').textContent = `${kv['device.android'] || '—'} (API ${kv['device.api'] || '?'})`;
  $('infoRoot').textContent = `${kv['root.impl'] || '—'} ${kv['root.version'] || ''}`.trim();
  $('infoSelinux').textContent = kv['root.selinux'] || '—';
  $('infoModule').textContent = kv['module.version'] || '—';

  const checks = [
    ['CPU frequency control', kv['cap.cpu'] === '1', 'cpufreq'],
    ['GPU frequency control', kv['cap.gpu'] === '1', kv['cap.gpu_driver'] || 'devfreq'],
    ['Battery temperature', !!kv['thermal.battery'], 'guard'],
    ['Top-app detection', kv['cap.topapp'] === '1', 'cpuset'],
    ['uclamp', kv['cap.uclamp'] === '1', 'scheduler'],
    ['Magisk DenyList', kv['cap.denylist'] === '1', 'root hiding'],
  ];
  $('capList').innerHTML = checks.map(([name, ok, note]) => `
    <li>
      <span class="mark ${ok ? 'yes' : 'meh'}">${ok ? '✓' : '!'}</span>
      <span class="name">${name}</span>
      <span class="note">${ok ? note : 'not exposed'}</span>
    </li>`).join('');
}

function render(kv, rows) {
  const ts = rows.find(r => r.type === 'ts');
  if (ts) {
    const d = new Date(parseInt(ts.f[0], 10) * 1000);
    $('tempHint').textContent = 'Battery temperature, last 2 minutes · updated ' +
      d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }
  renderStatus(kv);
  renderCpu(rows);
  renderTune(kv);
  renderInfo(kv);
  if (activeTab === 'logs') renderSessions(rows.filter(r => r.type === 'session'));
}

// ------------------------------------------------------------- sparkline --
function drawSpark(canvas, values, limit) {
  if (!canvas || typeof canvas.getContext !== 'function') return;
  const ctx = canvas.getContext('2d');
  if (!ctx) return; // no 2d context (rare WebViews): the numbers still show
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth || canvas.parentElement.clientWidth;
  const h = 48;
  canvas.width = Math.max(1, w * dpr);
  canvas.height = h * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  if (!values || values.length < 2) return;

  const min = Math.min(...values) - 1;
  const max = Math.max(...values, limit || 0) + 1;
  const span = Math.max(1, max - min);
  const X = i => (i / (values.length - 1)) * w;
  const Y = v => h - ((v - min) / span) * (h - 8) - 4;

  // limit line
  if (limit) {
    ctx.beginPath();
    ctx.setLineDash([3, 4]);
    ctx.strokeStyle = 'rgba(239,68,68,.45)';
    ctx.lineWidth = 1;
    ctx.moveTo(0, Y(limit));
    ctx.lineTo(w, Y(limit));
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // area
  ctx.beginPath();
  ctx.moveTo(0, h);
  values.forEach((v, i) => ctx.lineTo(X(i), Y(v)));
  ctx.lineTo(w, h);
  ctx.closePath();
  const g = ctx.createLinearGradient(0, 0, 0, h);
  g.addColorStop(0, 'rgba(34,211,167,.30)');
  g.addColorStop(1, 'rgba(34,211,167,0)');
  ctx.fillStyle = g;
  ctx.fill();

  // line
  ctx.beginPath();
  values.forEach((v, i) => (i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v))));
  ctx.strokeStyle = '#22d3a7';
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.stroke();
}

// ----------------------------------------------------------------- tabs ---
let activeTab = 'status';

function showTab(name) {
  activeTab = name;
  ['status', 'tune', 'logs', 'info'].forEach(t => {
    $('tab-' + t).hidden = t !== name;
  });
  document.querySelectorAll('.tabbtn').forEach(b => {
    b.classList.toggle('active', b.dataset.tab === name);
  });
  try { localStorage.setItem('codm.tab', name); } catch (e) { /* ignore */ }
  if (name === 'logs') loadLog();
  if (name === 'tune' || name === 'info') refresh(true);
}

document.querySelectorAll('.tabbtn').forEach(btn => {
  btn.addEventListener('click', () => showTab(btn.dataset.tab));
});

// --------------------------------------------------------------- actions --
async function act(args, okMsg, confirmMsg) {
  if (busy) return;
  if (confirmMsg && !window.confirm(confirmMsg)) return;
  busy = true;
  document.body.style.cursor = 'progress';
  try {
    const { kv } = await run(args);
    if (kv.ok === '1') toast(kv.msg || okMsg || 'done', 'okk');
    else toast(kv.msg || 'failed', 'err');
    await refresh(true);
    if (activeTab === 'logs') loadLog();
  } catch (e) {
    toast(String(e.message || e), 'err');
  } finally {
    busy = false;
    document.body.style.cursor = '';
  }
}

document.addEventListener('click', ev => {
  const actBtn = ev.target.closest('[data-act]');
  if (actBtn) {
    const a = actBtn.dataset.act;
    if (a === 'apply') act('apply', 'applied — press Release when you are done');
    else if (a === 'release') act('release', 'everything restored');
    else if (a === 'restart') act('engine restart', 'engine restarted');
    else if (a === 'reset') act('reset', 'reset to defaults',
      'Release everything and restore the default configuration?');
    else if (a === 'refresh-log') loadLog();
    else if (a === 'clear-log') act('clear_log', 'log cleared', 'Clear the module log?');
    return;
  }
  const prof = ev.target.closest('[data-profile]');
  if (prof) {
    act(`profile ${prof.dataset.profile}`, `${prof.dataset.profile} selected`);
  }
});

// -------------------------------------------------------------- controls --
function bindControl(el) {
  const key = el.dataset.key;
  const commit = async value => {
    el.dataset.pending = '1';
    el.disabled = true;
    try {
      let args;
      if (key === '__denylist') args = `denylist ${value === '1' ? 'on' : 'off'}`;
      else args = `set ${key} ${value}`;
      const { kv } = await run(args);
      if (kv.ok === '1') toast(kv.msg || 'saved', 'okk');
      else toast(kv.msg || 'rejected', 'err');
      await refresh(true);
    } catch (e) {
      toast(String(e.message || e), 'err');
    } finally {
      delete el.dataset.pending;
      el.disabled = false;
    }
  };

  if (el.type === 'checkbox') {
    el.addEventListener('change', () => commit(el.checked ? '1' : '0'));
  } else if (el.type === 'range') {
    let timer = null;
    const show = () => {
      const k = key;
      const v = el.value;
      if (k === 'TEMP_LIMIT_C') $('tempLimitOut').textContent = `${v} °C`;
      if (k === 'THERMAL_LIFT_C') {
        $('thermalLiftOut').textContent = `${v} °C`;
        $('thermalWarn').hidden = v === '0';
      }
      if (k === 'ADAPT_GPU_COOL') $('gpuCoolOut').textContent = `${v} %`;
      if (k === 'ADAPT_GPU_WARM') $('gpuWarmOut').textContent = `${v} %`;
      if (k === 'ADAPT_GPU_HOT') $('gpuHotOut').textContent = `${v} %`;
      if (k === 'ADAPT_HZ_HOT') $('hzHotOut').textContent = `${v} Hz`;
    };
    el.addEventListener('input', () => {
      show();
      const picked = el.value; // capture now: a refresh may re-render first
      el.dataset.pending = '1';
      clearTimeout(timer);
      timer = setTimeout(() => commit(picked), 650);
    });
  } else {
    el.addEventListener('change', () => commit(el.value));
  }
}

document.querySelectorAll('[data-key]').forEach(bindControl);

// ------------------------------------------------------------------ logs --
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

async function loadLog() {
  if (!bridgeOK) return;
  try {
    const { rows } = await run('log 150');
    const lines = rows.filter(r => r.type === 'log').map(r => r.f.join('|'));
    const box = $('logBox');
    if (!lines.length) {
      box.textContent = 'The log is empty.';
      return;
    }
    box.innerHTML = lines.map(line => {
      let cls = '';
      if (line.includes('[W]')) cls = 'w';
      if (line.includes('[E]')) cls = 'e';
      return `<span class="${cls}">${escapeHtml(line)}</span>`;
    }).join('\n');
    box.scrollTop = box.scrollHeight;
  } catch (e) {
    $('logBox').textContent = 'Could not read the log: ' + (e.message || e);
  }
  await loadSessions();
}

function renderSessions(rows) {
  const box = $('sessionList');
  if (!rows || !rows.length) {
    box.innerHTML = '<p class="empty">No sessions recorded yet.</p>';
    return;
  }
  box.innerHTML = rows.slice().reverse().map(({ f }) => {
    const [start, durMin, profile, maxT, end] = f;
    const dur = num(durMin, 0);
    return `<div class="session">
      <b>${fmtClock(start)}</b>
      <small>${PROFILE_INFO[profile]?.name || profile || '—'} · ${maxT && maxT !== '?' ? maxT + '°C peak' : 'no temperature'}</small>
      <span class="end">${fmtDuration(dur)}<br>${escapeHtml(end || '')}</span>
    </div>`;
  }).join('');
}

async function loadSessions() {
  try {
    const { rows } = await run('sessions');
    renderSessions(rows.filter(r => r.type === 'session'));
  } catch (e) { /* the tab already shows a message */ }
}

// ------------------------------------------------------------------ boot --
// -------------------------------------------------------- design preview --
// Opening this page with ?demo=1 from any static server renders the UI with
// sample data so the layout can be reviewed without a phone. Inside the
// KernelSU / APatch WebUI the bridge exists, so this branch is never taken.
const DEMO = new URLSearchParams(location.search).has('demo') && !bridge();

const DEMO_KV = {
  'module.version': 'v1.1.0',
  'device.model': 'POCO X5 Pro 5G',
  'device.soc': 'Snapdragon 778G',
  'device.android': '14',
  'device.api': '34',
  'root.impl': 'KernelSU',
  'root.version': '0.9.5',
  'root.selinux': 'Enforcing',
  'engine.running': '1',
  'engine.state': 'active',
  'cfg.profile': 'adaptive',
  'cfg.adaptive': '1',
  'cfg.engine_enabled': '1',
  'cfg.refresh_lock': '1',
  'cfg.refresh_hz': 'auto',
  'cfg.game_mode': '1',
  'cfg.game_mode_fps': '0',
  'cfg.game_mode_downscale': 'off',
  'cfg.verbose_log': '0',
  'cfg.temp_limit': '43',
  'cfg.thermal_lift': '0',
  'cfg.adapt_gpu_cool': '40',
  'cfg.adapt_gpu_warm': '28',
  'cfg.adapt_gpu_hot': '15',
  'cfg.adapt_hz_cool': 'auto',
  'cfg.adapt_hz_warm': 'auto',
  'cfg.adapt_hz_hot': '90',
  'cfg.poll_game': '5',
  'cfg.reapply': '120',
  'game.installed': 'com.activision.callofduty.shooter',
  'game.state': 'foreground',
  'thermal.battery': '38.4',
  'thermal.soc': '52',
  'thermal.limit': '43',
  'thermal.level': 'warm',
  'thermal.guard': 'ok',
  'display.max': '120',
  'display.min_setting': '60',
  'display.peak_setting': 'null',
  'gamemode.report': 'current mode: custom, available game modes: [standard, performance, battery]',
  'cap.cpu': '1',
  'cap.gpu': '1',
  'cap.gpu_driver': 'kgsl',
  'cap.uclamp': '1',
  'cap.topapp': '1',
  'cap.denylist': '0',
  'gpu.cur': '490',
  'gpu.min': '220',
  'gpu.max': '700',
  'session.last': '1793406000 1380 adaptive 41 thermal limit',
};

const DEMO_ROWS = [
  { type: 'ts', f: [String(Math.floor(Date.now() / 1000))] },
  { type: 'cpu', f: ['policy0', 'schedutil', '1267', '300', '1804'] },
  { type: 'cpu', f: ['policy4', 'schedutil', '1500', '710', '2400'] },
  { type: 'cpu', f: ['policy7', 'schedutil', '1800', '840', '2400'] },
];

const DEMO_SESSIONS = [
  { type: 'session', f: ['1793406000', '23', 'adaptive', '41', 'thermal limit'] },
  { type: 'session', f: ['1793300000', '47', 'adaptive', '42', 'game closed'] },
  { type: 'session', f: ['1793200000', '12', 'performance', '38', 'engine stopped'] },
  { type: 'session', f: ['1793100000', '61', 'adaptive', '—', 'battery low'] },
];

const DEMO_LOG = [
  '12:04:11 engine started (pid 4122)',
  '12:04:11 profile=adaptive temp_limit=43C guard=on',
  '12:09:32 CODM foreground — applying',
  '12:09:32 cpu policy0/4/7: schedutil 300..1804 MHz, ramp 2000us/4000us',
  '12:09:32 gpu floor 40% (280 MHz)',
  '12:14:02 thermal 39.2C >= limit-5 — step warm: gpu floor 28% (196 MHz)',
  '12:19:47 thermal 41.6C >= limit-2 — step hot: gpu floor 15%, refresh 90Hz',
  '12:21:03 CODM background — releasing',
  '12:21:03 restored 7 values from state/originals',
  '12:21:03 session recorded: 23 min peak 41C (thermal limit)',
].map(line => ({ type: 'log', f: [line] }));

async function demoRun(args) {
  await new Promise(done => setTimeout(done, 140)); // feel like a root call
  const [cmd, a, b] = args.split(/\s+/);
  if (cmd === 'snapshot') return { kv: Object.assign({}, DEMO_KV), rows: DEMO_ROWS };
  if (cmd === 'sessions') return { kv: { ok: '1' }, rows: DEMO_SESSIONS };
  if (cmd === 'log') return { kv: { ok: '1' }, rows: DEMO_LOG };
  if (cmd === 'set') {
    DEMO_KV[cfgKey(a)] = b;
    return { kv: { ok: '1', msg: `${a} set to ${b} (preview)` } };
  }
  if (cmd === 'profile') {
    if (!PROFILE_INFO[a]) return { kv: { ok: '0', msg: `unknown profile '${a}'` } };
    DEMO_KV['cfg.profile'] = a;
    DEMO_KV['cfg.adaptive'] = a === 'adaptive' ? '1' : '0';
    return { kv: { ok: '1', msg: `${a} selected (preview)` } };
  }
  if (cmd === 'denylist') return { kv: { ok: '0', msg: 'Magisk DenyList is not available on this device' } };
  return { kv: { ok: '1', msg: `${cmd} (preview — nothing changed)` } };
}

async function boot() {
  try { activeTab = localStorage.getItem('codm.tab') || 'status'; } catch (e) { /* ignore */ }
  if (!['status', 'tune', 'logs', 'info'].includes(activeTab)) activeTab = 'status';
  showTab(activeTab);

  if (DEMO) {
    bridgeOK = true;
    state.history = [33.1, 33.4, 33.9, 34.2, 34.8, 35.3, 35.1, 35.6, 36.2, 36.8,
      37.1, 37.4, 37.2, 37.6, 38.1, 38.4];
    $('bridgeWarning').hidden = false;
    $('bridgeWarning').querySelector('strong').textContent = 'Design preview.';
    $('bridgeWarning').querySelector('span:last-child').textContent =
      'Sample data — nothing is applied. Values here come from this page, not from the module.';
    await refresh();
    return;
  }

  const k = bridge();
  if (!k) {
    $('bridgeWarning').hidden = false;
    setPill('off', 'no bridge');
    $('deviceLine').textContent = 'open from KernelSU → Modules → Web UI';
    return;
  }

  bridgeOK = true;
  try {
    if (!(await resolveActions())) throw new Error('actions.sh not found');
    await refresh();
    setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      if (activeTab === 'status') refresh(true);
    }, 3000);
  } catch (e) {
    $('bridgeWarning').hidden = false;
    $('bridgeWarning').querySelector('strong').textContent = 'Could not reach the module.';
    setPill('off', 'error');
    toast(String(e.message || e), 'err');
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}
