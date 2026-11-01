/**
 * Project.Keynes Web shell watchdog (memory + crash flood guard).
 *
 * This file is copied next to the exported page by tools/patch_web_shell.py and
 * loaded with a plain <script src="pk_web_watchdog.js"></script>. It runs in the
 * page, not in the engine, and has no dependency on Godot API changes.
 *
 * Why it exists
 * -------------
 * A Godot Web build runs inside a single wasm32 linear memory whose hard ceiling
 * is 2 GiB (Emscripten MAXIMUM_MEMORY; the official Godot web templates cap it
 * there). When the simulation has grown the heap close to that ceiling, every
 * mouse move / wheel / click callback re-enters wasm, the allocation fails, the
 * engine prints the same "Cannot enlarge memory / mem is null" pair again, and a
 * broken function table then throws "table index is out of bounds" for every
 * input event. The result is a console with thousands of identical errors and
 * no usable diagnostic, plus a page that looks alive but is not.
 *
 * What it does
 * ------------
 *  1. Samples the wasm heap size and reports it to the local event channel
 *     (POST /_log, the same one WebTelemetry uses) as `pk_heap` every 10 s, so
 *     a long soak gives a heap-vs-day curve instead of a single dead end.
 *  2. Warns (non-blocking top bar) at 1900 MB and marks 2000 MB as critical.
 *  3. On the first unrecoverable heap error it shows one readable overlay,
 *     asks the engine to quit, detaches the canvas (which removes every
 *     Emscripten input listener attached to it), and suppresses the repeated
 *     error flood so the console keeps the first error only.
 *
 * It never throws into the page: every entry point is wrapped.
 */
(function () {
  'use strict';

  if (window.__pkWatchdog && window.__pkWatchdog.installed) {
    return; // already injected (double <script> must stay harmless)
  }

  var HEAP_WARN_MB = 1900;
  var HEAP_CRITICAL_MB = 2000;
  var SAMPLE_MS = 10000;
  var PROBE_MS = 2000;
  var MAX_ERRORS_AFTER_FATAL = 6;

  var state = {
    installed: true,
    fatal: false,
    warned: false,
    critical: false,
    errorsAfterFatal: 0,
    lastMb: -1,
    fatalText: ''
  };
  window.__pkWatchdog = state;

  function post(kind, extra) {
    try {
      var body = { e: kind, src: 'shell', ms: Math.round(performance.now()) };
      if (extra) {
        for (var k in extra) {
          if (Object.prototype.hasOwnProperty.call(extra, k)) {
            body[k] = extra[k];
          }
        }
      }
      fetch('/_log', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        keepalive: true
      }).catch(function () {});
    } catch (e) { /* static hosting / offline: telemetry is best effort */ }
  }

  function heapMb() {
    try {
      if (typeof engine === 'undefined' || !engine || !engine.rtenv) {
        return -1;
      }
      var heap = engine.rtenv.HEAPU8 || engine.rtenv.HEAP8;
      if (!heap || !heap.length) {
        return -1;
      }
      return Math.round(heap.length / 1048576);
    } catch (e) {
      return -1;
    }
  }

  function makeTopBar(text) {
    try {
      var bar = document.getElementById('pk-mem-bar');
      if (!bar) {
        bar = document.createElement('div');
        bar.id = 'pk-mem-bar';
        bar.style.cssText = [
          'position:fixed', 'left:0', 'right:0', 'top:0', 'z-index:2147483646',
          'padding:8px 12px', 'box-sizing:border-box', 'pointer-events:none',
          'background:rgba(122,18,18,0.94)', 'color:#fff',
          'font:14px/1.45 "Segoe UI",Arial,sans-serif', 'white-space:pre-line'
        ].join(';');
        (document.body || document.documentElement).appendChild(bar);
      }
      bar.textContent = text;
    } catch (e) { /* ignore */ }
  }

  function fatalOverlay(text) {
    try {
      if (document.getElementById('pk-mem-fatal')) {
        return;
      }
      var overlay = document.createElement('div');
      overlay.id = 'pk-mem-fatal';
      overlay.style.cssText = [
        'position:fixed', 'inset:0', 'z-index:2147483647',
        'background:#161616', 'color:#f2f2f2',
        'display:flex', 'align-items:center', 'justify-content:center',
        'font:15px/1.6 "Segoe UI",Arial,sans-serif'
      ].join(';');

      var box = document.createElement('div');
      box.style.cssText = 'max-width:660px;padding:28px 32px;';
      var title = document.createElement('div');
      title.style.cssText = 'font-size:20px;font-weight:600;margin-bottom:12px;color:#ff8a80;';
      title.textContent = '浏览器内存已耗尽 · WebAssembly heap exhausted';
      var body = document.createElement('div');
      body.style.whiteSpace = 'pre-line';
      body.textContent = text;
      var hint = document.createElement('div');
      hint.style.cssText = 'margin-top:16px;color:#b9b9b9;font-size:13px;';
      hint.textContent = '这是 Web 版 2 GB wasm 内存上限，不是存档损坏。刷新后可从最近的自动存档继续。';
      var btn = document.createElement('button');
      btn.textContent = '刷新页面 / Reload';
      btn.style.cssText = [
        'margin-top:20px', 'padding:9px 18px', 'border:0', 'border-radius:4px',
        'background:#c62828', 'color:#fff', 'font-size:15px', 'cursor:pointer'
      ].join(';');
      btn.onclick = function () { window.location.reload(); };

      box.appendChild(title);
      box.appendChild(body);
      box.appendChild(hint);
      box.appendChild(btn);
      overlay.appendChild(box);
      (document.body || document.documentElement).appendChild(overlay);
    } catch (e) { /* ignore */ }
  }

  function detachCanvas() {
    // Emscripten attaches its pointer/wheel/button listeners to the canvas.
    // Replacing the node detaches them without touching the engine's JS objects;
    // it is the difference between "one error" and "one error per mouse move".
    try {
      var canvas = document.querySelector('canvas');
      if (canvas && canvas.parentNode) {
        var clone = canvas.cloneNode(false);
        clone.id = canvas.id || 'canvas';
        canvas.parentNode.replaceChild(clone, canvas);
      }
    } catch (e) { /* ignore */ }
  }

  function goFatal(text) {
    if (state.fatal) {
      return;
    }
    state.fatal = true;
    state.fatalText = String(text || '').slice(0, 240);
    post('pk_heap_fatal', { msg: state.fatalText, mb: heapMb() });
    // One readable line for anyone with devtools open.
    try {
      console.warn('[pk-watchdog] wasm heap exhausted; stopping input and asking the engine to quit.');
    } catch (e) { /* ignore */ }
    detachCanvas();
    try {
      if (typeof engine !== 'undefined' && engine && engine.requestQuit) {
        engine.requestQuit();
      }
    } catch (e) { /* engine may already be wedged */ }
    fatalOverlay(
      '模拟在运行中耗尽了 2 GB WebAssembly 内存，引擎已停止。\n' +
      '最后一条错误：' + state.fatalText
    );
  }

  function isHeapFailure(text) {
    if (!text) {
      return false;
    }
    return text.indexOf('Cannot enlarge memory') >= 0 ||
      text.indexOf('Parameter "mem" is null') >= 0 ||
      text.indexOf('Parameter "mem_new" is null') >= 0 ||
      text.indexOf('out of memory') >= 0;
  }

  // Emscripten funnels its heap failures through printErr -> console.error.
  var origError = console.error;
  console.error = function () {
    try {
      var text = '';
      for (var i = 0; i < arguments.length; i++) {
        text += (i ? ' ' : '') + String(arguments[i]);
      }
      if (state.fatal) {
        state.errorsAfterFatal++;
        if (state.errorsAfterFatal > MAX_ERRORS_AFTER_FATAL) {
          return; // keep the console usable after the first real failure
        }
      } else if (isHeapFailure(text) || text.indexOf('table index is out of bounds') >= 0) {
        if (isHeapFailure(text)) {
          goFatal(text);
        }
      }
      return origError.apply(console, arguments);
    } catch (e) {
      try { return origError.apply(console, arguments); } catch (e2) { /* ignore */ }
    }
  };

  window.addEventListener('error', function (ev) {
    try {
      var msg = String((ev && (ev.message || (ev.error && ev.error.message))) || '');
      if (!msg) {
        return;
      }
      if (state.fatal) {
        // The engine keeps throwing from its main loop after the heap died;
        // preventDefault stops the browser from printing each one.
        if (ev.preventDefault) {
          ev.preventDefault();
        }
        return;
      }
      if (isHeapFailure(msg) || msg.indexOf('table index is out of bounds') >= 0) {
        if (ev.preventDefault) {
          ev.preventDefault();
        }
        goFatal(msg);
      }
    } catch (e) { /* ignore */ }
  }, false);

  window.addEventListener('unhandledrejection', function (ev) {
    try {
      if (state.fatal && ev.preventDefault) {
        ev.preventDefault();
      }
    } catch (e) { /* ignore */ }
  }, false);

  function probe() {
    var mb = heapMb();
    if (mb < 0) {
      setTimeout(probe, 500);
      return;
    }
    state.lastMb = mb;
    post('pk_heap_start', { mb: mb });
    setTimeout(sample, SAMPLE_MS);
  }

  function sample() {
    try {
      var mb = heapMb();
      if (mb >= 0) {
        state.lastMb = mb;
        post('pk_heap', { mb: mb });
        if (mb >= HEAP_WARN_MB && !state.warned) {
          state.warned = true;
          post('pk_heap_high', { mb: mb });
          makeTopBar('警告：Web 版 wasm 内存已用到 ' + mb + ' MB / 2048 MB。\n' +
            '建议保存后刷新页面，否则可能崩溃（Web 版无法突破 2 GB 上限）。');
        }
        if (mb >= HEAP_CRITICAL_MB && !state.critical) {
          state.critical = true;
          post('pk_heap_critical', { mb: mb });
        }
      }
    } catch (e) { /* ignore */ }
    setTimeout(sample, SAMPLE_MS);
  }

  // Browser-side lifecycle hooks. Kept here (a normal <script> in the page)
  // rather than JavaScriptBridge.eval: an eval-based hook installer was tried
  // earlier and made the Web page freeze after one frame, so page-side JS is
  // the only place these may live.
  try {
    var hookedCanvas = document.querySelector('canvas');
    if (hookedCanvas) {
      hookedCanvas.addEventListener('webglcontextlost', function (ev) {
        post('pk_gl_lost', { reason: String((ev && ev.statusMessage) || '') });
      }, false);
    }
    window.addEventListener('pagehide', function () { post('pk_page_hide', {}); }, false);
  } catch (e) { /* ignore */ }

  // Wait for the engine instance (declared by ProjectKeynes.html) and its runtime.
  setTimeout(probe, PROBE_MS);
})();
