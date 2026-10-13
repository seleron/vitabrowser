/* hCaptcha hsw, recorded for replay (tools/hcaptcha/hsw-replay.js): the
 * module's bytes, every call JavaScript makes into it (export or table
 * function: arguments, result or exception, and the linear-memory bytes JS
 * wrote since the previous call returned) and every import call the module
 * makes from such a call (arguments, the value returned or the exception,
 * and the memory bytes written while it ran -- nested calls back into the
 * module included). Calls into the module made from inside an import are
 * not separate events: their effect is in that import's memory diff.
 * Everything the computation takes from outside is then in the record, so a
 * replay is deterministic and any engine can be checked against it.
 *
 * In api.hcaptcha.com frames only. Chromium: chrome-demo.py --record DIR
 * (Playwright init script, events sent through the __hswRec binding).
 * Event lines, each followed by its memory writes ("W off hex", "G size"):
 *   X <fn> <args>             a call into the module (writes: JS's, before it)
 *   R <result> | H<memhash>   its return, and a hash of all of memory
 *   E <message>               ...or its exception
 *   I <import> <args> | P<i>=<hash>...  an import call; P: the bytes at
 *                             (arg i, arg i+1) when that can be (ptr, len)
 *   i <result> / t <message>  its return or exception (writes: during it)
 * A line starts with the instance number; "M <n> <hex>" is a module. */
(function () {
  if (!/hcaptcha\.com$/.test(location.host) || typeof WebAssembly !== 'object') return;
  var W = WebAssembly, fm = /frame=(\w+)/.exec(location.hash || '');
  var tag = (fm ? fm[1] : '-') + '.' + Math.random().toString(36).slice(2, 7);
  /* Without the binding (the simulator, VITA_SIM_INJECT) the record goes
   * to console.log, which the engine log keeps one line per call, newlines
   * made spaces, at most ~2 KB: one event per call, long ones split
   * ("HSWREC <tag> + <chunk>" continues the line before; sim-rec.py joins
   * them). And it is light there: no memory diffs or memory hashes --
   * QuickJS scanning 1.2 MB around each of ~17000 import calls would take
   * hours and the script budget -- so a light record is for comparing
   * with Chromium's (hsw-compare.py), not for replaying. */
  /* (in the simulator harness-names.js puts stand-ins named __hswStandIn
   * for Chromium's binding functions, so the two windows list alike) */
  var LIGHT = typeof __hswRec !== 'function' || __hswRec.name === '__hswStandIn';
  var send = !LIGHT ? __hswRec : function (s) {
    var ls = s.split('\n'), t = ls.shift();
    ls.forEach(function (l) {
      for (var o = 0; o < l.length || o === 0; o += 1800) console.log('HSWREC ' + t + (o ? ' + ' : ' : ') + l.slice(o, o + 1800));
    });
  };
  var buf = [], ninst = 0;
  function flush() { if (buf.length) { var s = buf.join('\n'); buf = []; try { send(tag + '\n' + s); } catch (e) {} } }
  setInterval(flush, 500);
  function hex(u, a, b) { var s = ''; for (var i = a; i < b; i++) s += (u[i] < 16 ? '0' : '') + u[i].toString(16); return s; }
  function V(v) {
    var t = typeof v;
    if (t === 'number') return Object.is(v, -0) ? 'n-0' : 'n' + v;
    if (t === 'bigint') return 'b' + v;
    if (t === 'undefined') return 'u';
    if (v === null) return 'N';
    if (t === 'boolean') return v ? 'T' : 'F';
    if (t === 'string') return 's' + JSON.stringify(v);
    var n; try { n = Number(v); } catch (e) { n = NaN; }
    return 'o' + n;
  }
  function mod(rec, m) {
    /* per instance: memory, a shadow copy to diff against, call depth */
    var st = { mem: m, shadow: null, depth: 0, id: rec };
    st.snap = function () {
      if (!st.mem || LIGHT) return;
      var b = new Uint8Array(st.mem.buffer);
      if (!st.shadow || st.shadow.length !== b.length) st.shadow = new Uint8Array(b.length);
      st.shadow.set(b);
    };
    st.diff = function () {
      if (!st.mem || LIGHT) return '';
      var b = new Uint8Array(st.mem.buffer), s = st.shadow, out = [], n = b.length, sl = s ? s.length : 0;
      var b4 = new Int32Array(st.mem.buffer, 0, n >> 2), s4 = s ? new Int32Array(s.buffer, 0, sl >> 2) : null;
      var i = 0, lim4 = Math.min(n, sl) >> 2;
      while (i < lim4) {
        if (b4[i] === s4[i]) { i++; continue; }
        var a = i << 2, e = i + 1;
        while (e < lim4 && (b4[e] !== s4[e] || (e + 1 < lim4 && b4[e + 1] !== s4[e + 1]) || (e + 2 < lim4 && b4[e + 2] !== s4[e + 2]))) e++;
        out.push('W ' + a + ' ' + hex(b, a, e << 2));
        i = e;
      }
      for (var j = lim4 << 2; j < n; j++) {
        if ((j < sl ? s[j] : 0) === b[j]) continue;
        var k = j; while (k < n && (k < sl ? s[k] : 0) !== b[k]) k++;
        out.push('W ' + j + ' ' + hex(b, j, k)); j = k;
      }
      return (n !== sl ? 'G ' + n + '\n' : '') + out.join('\n');
    };
    return st;
  }
  function A(args) { var a = []; for (var i = 0; i < args.length; i++) a.push(V(args[i])); return a.join(' '); }
  /* what the module hands an import through memory: each argument pair
   * that could be (pointer, length) gets the hash of those bytes; after
   * each call, the hash of all of memory (hsw-replay.js computes the same) */
  function hb(u, a, b) { var h = 0x811c9dc5; for (var i = a; i < b; i++) h = Math.imul(h ^ u[i], 16777619); return (h >>> 0).toString(16); }
  function hm(m) { if (!m || LIGHT) return '-'; var w = new Int32Array(m.buffer), h = 0; for (var i = 0; i < w.length; i++) h = (Math.imul(h, 31) + w[i]) | 0; return w.length + ':' + (h >>> 0).toString(16); }
  /* the bytes behind a large (pointer, length) argument -- what hsw hands
   * JS as text, its payload among them: "K mem <arg> <length> <json>" */
  function big(st, args) {
    if (!st.mem) return;
    var u = new Uint8Array(st.mem.buffer);
    for (var i = 0; i + 1 < args.length; i++) {
      var p = args[i], l = args[i + 1];
      if (typeof p === 'number' && typeof l === 'number' && l >= 2000 && l <= 262144 && p > 0 && (p | 0) === p && p + l <= u.length) {
        var t = '';
        for (var j = p; j < p + l; j += 4096) t += String.fromCharCode.apply(null, u.subarray(j, Math.min(p + l, j + 4096)));
        ev(st, 'K mem ' + i + ' ' + l + ' ' + JSON.stringify(t));
      }
    }
  }
  function P(st, args) {
    if (!st.mem) return '';
    var u = new Uint8Array(st.mem.buffer), n = u.length, r = '';
    for (var i = 0; i + 1 < args.length; i++) {
      var p = args[i], l = args[i + 1];
      if (typeof p === 'number' && typeof l === 'number' && p >= 0 && l > 0 && l <= 1048576 && (p | 0) === p && (l | 0) === l && p + l <= n)
        r += ' P' + i + '=' + hb(u, p, p + l);
    }
    return r;
  }
  /* the simulator runs no timer an injected script sets (patch 268), so
   * there nothing may wait for the interval: every event goes out at once */
  function ev(st, line, w) { buf.push(st.id + ' ' + line); if (w) buf.push(w); if (LIGHT || buf.length > 4000) flush(); }
  function wrapImports(st, imports) {
    if (!imports || typeof imports !== 'object') return imports;
    var out = {};
    Object.keys(imports).forEach(function (m) {
      var o = imports[m], c = {};
      if (!o || typeof o !== 'object') { out[m] = o; return; }
      Object.keys(o).forEach(function (k) {
        var f = o[k];
        if (f instanceof W.Memory) st.mem = st.mem || f;
        if (typeof f !== 'function') { c[k] = f; return; }
        var name = m + '.' + k;
        c[k] = function () {
          if (st.depth !== 1) return f.apply(this, arguments);
          ev(st, 'I ' + name + ' ' + A(arguments) + ' |' + P(st, arguments));
          big(st, arguments);
          st.snap();
          var r;
          cur = st;
          try { r = f.apply(this, arguments); }
          catch (e) { cur = null; ev(st, 't ' + JSON.stringify(String(e && e.message)), st.diff()); throw e; }
          cur = null;
          ev(st, 'i ' + V(r), st.diff());
          return r;
        };
      });
      out[m] = c;
    });
    return out;
  }
  function wrapFn(st, f, name) {
    return function () {
      if (st.depth > 0) { st.depth++; try { return f.apply(this, arguments); } finally { st.depth--; } }
      ev(st, 'X ' + name + ' ' + A(arguments), st.diff());
      st.depth = 1;
      var r;
      try { r = f.apply(this, arguments); }
      catch (e) { st.depth = 0; ev(st, 'E ' + JSON.stringify(String(e && e.message))); st.snap(); throw e; }
      st.depth = 0;
      ev(st, 'R ' + V(r) + ' | H' + hm(st.mem)); st.snap();
      return r;
    };
  }
  /* what hsw's glue probes with (Reflect.has / get), as notes in the
   * stream: "K has|get <object> <key> = <result>", inside the import that
   * made them (replay skips them; hsw-compare.py shows them) */
  function D(o) {
    if (o === window) return 'window';
    if (o === navigator) return 'navigator';
    if (o === document) return 'document';
    if (o === screen) return 'screen';
    if (o === performance) return 'performance';
    var t = typeof o;
    if (t === 'function') return 'fn:' + (o.name || '?');
    if (o === null) return 'null';
    if (t === 'string') return 's' + JSON.stringify(o.slice(0, 60));
    if (t !== 'object') return String(o).slice(0, 60);
    try { return 'o:' + Object.prototype.toString.call(o).slice(8, -1); } catch (e) { return 'o:?'; }
  }
  var cur = null, RH = Reflect.has, RG = Reflect.get;
  Reflect.has = function (o, k) { var r = RH(o, k); if (cur) ev(cur, 'K has ' + D(o) + ' ' + String(k).slice(0, 80) + ' = ' + r); return r; };
  var RO = Reflect.ownKeys;
  Reflect.ownKeys = function (o) { var r = RO(o); if (cur) ev(cur, 'K ownKeys ' + D(o) + ' = ' + r.length + ' ' + r.slice(0, 40).map(String).join(',').slice(0, 600)); return r; };
  ['keys', 'getOwnPropertyNames', 'values', 'entries'].forEach(function (m) {
    var f = Object[m];
    Object[m] = function (o) { var r = f(o); if (cur) ev(cur, 'K ' + m + ' ' + D(o) + ' = ' + r.length + ' ' + r.map(function (x) { return typeof x === 'string' ? x : D(x); }).join(',').slice(0, 20000)); return r; };
  });
  /* long strings the glue hands the module (what hsw encrypts goes in as
   * text): "K enc <length> <text>" on the latest instance */
  var lastSt = null;
  if (typeof TextEncoder === 'function') ['encode', 'encodeInto'].forEach(function (m) {
    var f = TextEncoder.prototype[m];
    if (typeof f !== 'function') return;
    TextEncoder.prototype[m] = function (str) {
      if (lastSt && typeof str === 'string' && str.length > 300) ev(lastSt, 'K enc ' + str.length + ' ' + str.slice(0, 60000).replace(/[\r\n]/g, ' '));
      return f.apply(this, arguments);
    };
  });
  /* JS's writes into the module's memory, caught at the writers (typed
   * array set, DataView setters, the natives that fill a view) instead of
   * diffing all of memory: "w <offset> <hex>" on the latest instance */
  function onMem(view) { return lastSt && lastSt.mem && view && view.buffer === lastSt.mem.buffer; }
  function wlog(view, off, n) {
    var u = new Uint8Array(view.buffer, view.byteOffset + off, n);
    buf.push(lastSt.id + ' w ' + (view.byteOffset + off) + ' ' + hex(u, 0, n));
  }
  (function () {
    var TA = Object.getPrototypeOf(Uint8Array.prototype), tset = TA.set;
    TA.set = function (src, off) {
      var r = tset.apply(this, arguments);
      if (onMem(this)) { var n = (src && src.length) || 0, o = (off || 0) * this.BYTES_PER_ELEMENT; wlog(this, o, n * this.BYTES_PER_ELEMENT); }
      return r;
    };
    var DV = DataView.prototype;
    [['setInt8', 1], ['setUint8', 1], ['setInt16', 2], ['setUint16', 2], ['setInt32', 4], ['setUint32', 4],
     ['setFloat32', 4], ['setFloat64', 8], ['setBigInt64', 8], ['setBigUint64', 8]].forEach(function (m) {
      var f = DV[m[0]]; if (!f) return;
      DV[m[0]] = function (o) { var r = f.apply(this, arguments); if (onMem(this)) wlog(this, o, m[1]); return r; };
    });
    if (typeof TextEncoder === 'function' && TextEncoder.prototype.encodeInto) {
      var ei = TextEncoder.prototype.encodeInto;
      TextEncoder.prototype.encodeInto = function (str, view) { var r = ei.apply(this, arguments); if (onMem(view) && r && r.written) wlog(view, 0, r.written); return r; };
    }
    if (window.crypto && crypto.getRandomValues) {
      var gr = crypto.getRandomValues;
      crypto.getRandomValues = function (view) { var r = gr.call(crypto, view); if (onMem(view)) wlog(view, 0, view.byteLength); return r; };
    }
  })();
  /* JSON the page builds or reads while the module is live: "K json
   * stringify|parse <length> <text>" for the long ones */
  ['stringify', 'parse'].forEach(function (m) {
    var f = JSON[m];
    JSON[m] = function (x) {
      var r = f.apply(JSON, arguments), t = m === 'stringify' ? r : x;
      if (lastSt && typeof t === 'string' && t.length >= 200) ev(lastSt, 'K json ' + m + ' ' + t.length + ' ' + t.slice(0, 60000).replace(/[\r\n]/g, ' '));
      return r;
    };
  });
  var GOPD = Object.getOwnPropertyDescriptor;
  Object.getOwnPropertyDescriptor = function (o, k) {
    var r = GOPD(o, k);
    if (cur) ev(cur, 'K gopd ' + D(o) + ' ' + String(k).slice(0, 80) + ' = ' + (r ? ('value' in r ? 'value:' + D(r.value) : 'get:' + D(r.get) + ' set:' + D(r.set)) + (r.enumerable ? ' E' : '') + (r.configurable ? ' C' : '') + (r.writable ? ' W' : '') : 'none'));
    return r;
  };
  Reflect.getOwnPropertyDescriptor = function (o, k) { return Object.getOwnPropertyDescriptor(o, k); };
  Reflect.get = function (o, k, rc) { var r = arguments.length > 2 ? RG(o, k, rc) : RG(o, k); if (cur) ev(cur, 'K get ' + D(o) + ' ' + String(k).slice(0, 80) + ' = ' + D(r)); return r; };
  var tables = new WeakMap();
  var TG = W.Table.prototype.get;
  W.Table.prototype.get = function (i) {
    var f = TG.call(this, i), t = tables.get(this);
    if (!t || typeof f !== 'function') return f;
    return wrapFn(t.st, f, 'tbl:' + t.name + ':' + i);
  };
  function wrapInstance(st, inst) {
    var ex = inst.exports, w = {};
    Object.keys(ex).forEach(function (k) {
      var v = ex[k];
      if (v instanceof W.Memory) st.mem = st.mem || v;
      if (v instanceof W.Table) tables.set(v, { st: st, name: k });
      w[k] = typeof v === 'function' ? wrapFn(st, v, k) : v;
    });
    st.snap();
    var fake = Object.create(W.Instance.prototype);
    Object.defineProperty(fake, 'exports', { value: Object.freeze(w), enumerable: true });
    return fake;
  }
  function bytesOf(src) {
    if (src instanceof ArrayBuffer) return new Uint8Array(src);
    if (ArrayBuffer.isView(src)) return new Uint8Array(src.buffer, src.byteOffset, src.byteLength);
    return null;
  }
  var modIds = new WeakMap(), nmod = 0;
  function noteModule(m, bytes) {
    if (bytes) { modIds.set(m, nmod); buf.push('M ' + (nmod++) + ' ' + (LIGHT ? 'len' + bytes.length + ':' + hb(bytes, 0, bytes.length) : hex(bytes, 0, bytes.length))); flush(); }
  }
  function begin(m, imports) {
    var st = mod(ninst++, null);
    lastSt = st;
    buf.push(st.id + ' INSTANCE ' + (modIds.has(m) ? modIds.get(m) : '?'));
    /* the window's own names as hsw will find them (it walks them) */
    try { buf.push(st.id + ' K names ' + Object.getOwnPropertyNames(window).join(',')); } catch (e) {}
    /* own keys of what fingerprinters walk: a browser keeps its API on the
     * prototypes (navigator's own keys are [] in Chromium) */
    try {
      var objs = { navigator: navigator, document: document, screen: screen, performance: performance, location: location,
        history: history, 'Window.prototype': Object.getPrototypeOf(window), 'Navigator.prototype': Object.getPrototypeOf(navigator),
        'Document.prototype': Object.getPrototypeOf(document), documentElement: document.documentElement, body: document.body,
        'HTMLElement.prototype': HTMLElement.prototype, 'Element.prototype': Element.prototype, 'Node.prototype': Node.prototype,
        'EventTarget.prototype': EventTarget.prototype, 'Function.prototype': Function.prototype, 'Object.prototype': Object.prototype,
        Math: Math, JSON: JSON, console: console, crypto: window.crypto, 'screen.orientation': screen.orientation };
      Object.keys(objs).forEach(function (k) { var v = objs[k]; buf.push(st.id + ' K own ' + k + ' = ' + (v ? RO(v).map(String).join(',') : 'none')); });
    } catch (e) { buf.push(st.id + ' K own error ' + e); }
    try { buf.push(st.id + ' K symbols ' + Object.getOwnPropertySymbols(window).map(function (y) { var d = Object.getOwnPropertyDescriptor(window, y); return String(y) + '=' + D(d.value !== undefined ? d.value : d.get) + (d.enumerable ? ':E' : '') + (d.writable ? ':W' : '') + (d.configurable ? ':C' : ''); }).join(',')); } catch (e) {}
    return { st: st, imports: wrapImports(st, imports) };
  }
  var oInst = W.instantiate, oStream = W.instantiateStreaming, OI = W.Instance, OM = W.Module, oCompile = W.compile;
  W.Module = function Module(b) { var m = new OM(b); noteModule(m, bytesOf(b)); return m; };
  W.Module.prototype = OM.prototype;
  Object.setPrototypeOf(W.Module, OM);
  W.compile = function (b) { var by = bytesOf(b); return oCompile.call(W, b).then(function (m) { noteModule(m, by); return m; }); };
  W.Instance = function Instance(m, imp) { var s = begin(m, imp); return wrapInstance(s.st, new OI(m, s.imports)); };
  W.Instance.prototype = OI.prototype;
  W.instantiate = function (b, imp) {
    if (b instanceof OM) { var s = begin(b, imp); return oInst.call(W, b, s.imports).then(function (i) { return wrapInstance(s.st, i); }); }
    var by = bytesOf(b);
    return oCompile.call(W, b).then(function (m) {
      noteModule(m, by);
      var s = begin(m, imp);
      return oInst.call(W, m, s.imports).then(function (i) { return { module: m, instance: wrapInstance(s.st, i) }; });
    });
  };
  if (oStream) W.instantiateStreaming = function (resp, imp) {
    return Promise.resolve(resp).then(function (r) { return r.arrayBuffer(); }).then(function (ab) { return W.instantiate(ab, imp); });
  };
  W.compileStreaming = function (resp) {
    return Promise.resolve(resp).then(function (r) { return r.arrayBuffer(); }).then(function (ab) { return W.compile(ab); });
  };
  addEventListener('pagehide', flush);
})();
