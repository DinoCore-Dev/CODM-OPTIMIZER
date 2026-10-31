#!/usr/bin/env node
/* Headless smoke test for module/webroot.
 *
 * Loads index.html in jsdom, evaluates app.js with ?demo=1 (sample data, no
 * bridge) and asserts that every panel actually renders and that a tap on a
 * control reaches the right place. This catches what a shell lint cannot:
 * a JS syntax error, a missing element id, a renderer that throws halfway
 * through and leaves the page blank.
 *
 * Optional tooling — skipped when jsdom is not installed:
 *
 *     npm install jsdom && node tools/uitest.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

let JSDOM, VirtualConsole;
try {
  ({ JSDOM, VirtualConsole } = require('jsdom'));
} catch (e) {
  console.log('SKIP: jsdom is not installed (npm install jsdom)');
  process.exit(0);
}

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'module/webroot/index.html'), 'utf8');
const js = fs.readFileSync(path.join(root, 'module/webroot/app.js'), 'utf8');

const errors = [];
const vc = new VirtualConsole();
vc.on('jsdomError', e => {
  const msg = String((e && e.message) || e);
  // jsdom ships no canvas backend; getContext() therefore reports "not
  // implemented" and returns null. drawSpark handles null, so ignore it.
  if (/getContext|Not implemented/.test(msg)) return;
  errors.push('jsdom: ' + msg);
});

const dom = new JSDOM(html, {
  url: 'https://ui.test/?demo=1',
  runScripts: 'outside-only',
  pretendToBeVisual: true,
  virtualConsole: vc,
});
const win = dom.window;
const doc = win.document;
const $ = id => doc.getElementById(id);
const sleep = ms => new Promise(r => setTimeout(r, ms));

let pass = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) { pass++; return; }
  failures.push(name + (detail !== undefined ? ` (got: ${JSON.stringify(detail)})` : ''));
}
const text = id => ($(id) ? $(id).textContent.trim() : '<missing #' + id + '>');

(async () => {
  try {
    win.eval(js);
  } catch (e) {
    console.log('FAIL: app.js threw while loading: ' + e.message);
    process.exit(1);
  }
  await sleep(700); // boot() + first snapshot

  // --- status tab -------------------------------------------------------
  check('pill shows the running profile', text('statusText') === 'in game', text('statusText'));
  check('hero profile is Adaptive', text('heroProfile') === 'Adaptive', text('heroProfile'));
  check('hero subtitle names the thermal step', /warm/.test(text('heroProfileSub')), text('heroProfileSub'));
  check('battery temperature is rendered', text('gaugeValue') === '38', text('gaugeValue'));
  check('SoC temperature is rendered', text('socTemp') === '52°C', text('socTemp'));
  check('guard reads ok', text('guardState') === 'ok', text('guardState'));
  check('adaptive step shown', text('adaptLevel') === 'warm', text('adaptLevel'));
  check('engine chip is on', /^on/.test(text('engineChip')), text('engineChip'));
  check('game package listed', /activision/.test(text('rowGame')), text('rowGame'));
  check('game state worded for humans', text('rowDetect') === 'in foreground', text('rowDetect'));
  check('panel refresh rate shown', text('rowPanel') === '120 Hz', text('rowPanel'));
  check('unset peak setting reads "default"', text('rowRefresh') === '60 / default', text('rowRefresh'));
  check('game mode parsed from the report', text('rowGamemode') === 'custom', text('rowGamemode'));
  check('last session summarised', /23 min/.test(text('rowSession')), text('rowSession'));
  check('device line filled', /POCO X5 Pro/.test(text('deviceLine')), text('deviceLine'));
  check('cpu list has three policies', $('cpuList').querySelectorAll('.cpu-item').length === 3);
  check('gpu panel shows a frequency', /MHz/.test($('gpuBody').textContent), $('gpuBody').textContent);
  check('cpu chip is controllable', text('cpuChip') === 'controllable', text('cpuChip'));

  // --- tune tab ---------------------------------------------------------
  doc.querySelector('[data-tab="tune"]').click();
  await sleep(60);
  check('tune tab becomes visible', $('tab-tune').hidden === false);
  check('status tab hidden', $('tab-status').hidden === true);
  check('five profiles offered', $('profileList').querySelectorAll('[data-profile]').length === 5);
  check('active profile marked', $('profileList').querySelector('.profile.active').dataset.profile === 'adaptive');
  check('slider readout for temp limit', text('tempLimitOut') === '43 °C', text('tempLimitOut'));
  check('thermal lift readout', text('thermalLiftOut') === '0 °C', text('thermalLiftOut'));
  check('lift warning hidden at 0', $('thermalWarn').hidden === true);
  check('gpu floor readouts', text('gpuCoolOut') === '40 %' && text('gpuHotOut') === '15 %',
    text('gpuCoolOut') + ' / ' + text('gpuHotOut'));

  const temp = doc.querySelector('[data-key="TEMP_LIMIT_C"]');
  check('temp slider takes the config value', temp.value === '43', temp.value);
  const hz = doc.querySelector('[data-key="REFRESH_HZ"]');
  check('refresh select takes "auto"', hz.value === 'auto', hz.value);
  const eng = doc.querySelector('[data-key="ENGINE_ENABLED"]');
  check('engine toggle reflects config', eng.checked === true);
  check('denylist row hidden without Magisk', $('denylistRow').hidden === true);

  // drag the temperature slider -> debounced set
  temp.value = '41';
  temp.dispatchEvent(new win.Event('input', { bubbles: true }));
  check('slider updates its own readout live', text('tempLimitOut') === '41 °C', text('tempLimitOut'));
  await sleep(900);
  check('slider write reaches the bridge', /41/.test(text('toast')), text('toast'));

  // pick another profile
  doc.querySelector('[data-profile="performance"]').click();
  await sleep(600);
  check('profile click applied', $('profileList').querySelector('.profile.active').dataset.profile === 'performance');
  check('profile click confirmed in the toast', /performance/.test(text('toast')), text('toast'));

  // --- logs tab ---------------------------------------------------------
  doc.querySelector('[data-tab="logs"]').click();
  await sleep(900);
  check('log lines rendered', $('logBox').textContent.split('\n').length >= 8);
  check('log text is escaped, not injected', $('logBox').querySelectorAll('b,img,script').length === 0);
  check('sessions rendered', $('sessionList').querySelectorAll('.session').length === 4);
  check('session duration humanised', /23 min/.test($('sessionList').textContent));

  // --- info tab ---------------------------------------------------------
  doc.querySelector('[data-tab="info"]').click();
  await sleep(60);
  check('model in info', text('infoModel') === 'POCO X5 Pro 5G', text('infoModel'));
  check('module version in info', text('infoModule') === 'v1.1.0', text('infoModule'));
  check('capabilities listed', $('capList').querySelectorAll('li').length === 6);
  check('denylist reported as missing', /not exposed/.test($('capList').textContent));

  // --- robustness -------------------------------------------------------
  check('no runtime errors', errors.length === 0, errors.join(' | '));

  if (failures.length) {
    console.log(`FAIL: ${failures.length} web UI check(s) failed`);
    failures.forEach(f => console.log('  - ' + f));
    process.exit(1);
  }
  console.log(`ok: ${pass} web UI checks passed`);
  process.exit(0);
})();
