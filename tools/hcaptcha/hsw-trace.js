/* hCaptcha hsw, traced: every import call (arguments, result or exception),
 * Reflect.has / Reflect.get, exceptions the glue swallows (through
 * Function.prototype.apply), the getcaptcha / checksiteconfig XHRs with
 * their answers. In api.hcaptcha.com frames only. Chromium: Playwright
 * add_init_script; the simulator: VITA_SIM_INJECT=<this file> (patch 268).
 * Lines start "HT <host>:<frame> <seq> ". */
(function () {
  if (!/hcaptcha\.com$/.test(location.host) || typeof WebAssembly !== 'object') return;
  var fm = /frame=(\w+)/.exec(location.hash || ''), tag = location.host.split('.')[0] + ':' + (fm ? fm[1] : '-');
  var W = WebAssembly, seq = 0, MAX = 40000, inst = 0, mem = null;
  function str(p, n) {
    if (!mem || typeof p !== 'number' || typeof n !== 'number' || n <= 0 || n > 200 || p < 0 || p + n > mem.buffer.byteLength) return '';
    var u = new Uint8Array(mem.buffer, p, n), t = '';
    for (var i = 0; i < n; i++) { if (u[i] < 32 || u[i] > 126) return ''; t += String.fromCharCode(u[i]); }
    return ' ~' + JSON.stringify(t);
  }
  function grab(r) { try { var e = (r && r.instance ? r.instance : r).exports; for (var k in e) if (e[k] instanceof W.Memory) mem = e[k]; } catch (x) {} return r; }
  function S(v) {
    var t = typeof v;
    if (v === null) return 'null';
    if (t === 'number') return v !== v ? 'NaN' : String(v);
    if (t === 'string') return 's' + v.length + ':' + JSON.stringify(v.slice(0, 48));
    if (t === 'boolean' || t === 'undefined' || t === 'bigint') return String(v);
    if (t === 'function') return 'fn:' + (v.name || '?');
    try { return 'o:' + Object.prototype.toString.call(v).slice(8, -1); } catch (e) { return 'o:?'; }
  }
  function out(line) { if (seq < MAX) console.log('HT ' + tag + ' ' + (seq++) + ' ' + line); }
  function wrap(imports) {
    if (!imports || typeof imports !== 'object') return imports;
    var n = inst++;
    Object.keys(imports).forEach(function (m) {
      var o = imports[m];
      if (!o || typeof o !== 'object') return;
      Object.keys(o).forEach(function (k) {
        var f = o[k];
        if (typeof f !== 'function') return;
        var name = n + ':' + m + '.' + k;
        if (/^(ea|ta|ka|Bb|C|i|Na|ua|ic|h|Za|Va|Zb|l|Da|jb)$/.test(k)) out('SRC ' + k + ' ' + String(f).replace(/\s+/g, ' ').slice(0, 400));
        o[k] = function () {
          var a = [];
          for (var i = 0; i < arguments.length; i++) a.push(S(arguments[i]));
          var r;
          try { r = f.apply(this, arguments); }
          catch (e) { out(name + '(' + a.join(',') + ') THROW ' + S(e) + ' ' + String(e && e.message).slice(0, 80)); throw e; }
          out(name + '(' + a.join(',') + ')=' + S(r) + (arguments.length === 2 ? str(arguments[0], arguments[1]) : ''));
          return r;
        };
      });
    });
    out('INSTANCE ' + n + ' imports ' + Object.keys(imports).map(function (m) { return m + ':' + Object.keys(imports[m] || {}).length; }).join(','));
    return imports;
  }
  function desc(o) {
    if (o === window) return 'window';
    if (o === navigator) return 'navigator';
    if (o === document) return 'document';
    if (o === screen) return 'screen';
    if (o === performance) return 'performance';
    var t = typeof o;
    if (t === 'function') return 'fn:' + (o.name || '?');
    if (o === null || (t !== 'object')) return S(o);
    try { var c = o.constructor && o.constructor.name; return 'o:' + Object.prototype.toString.call(o).slice(8, -1) + (c ? '/' + c : ''); } catch (e) { return 'o:?'; }
  }
  var FA = Function.prototype.apply, FC = Function.prototype.call, inApply = false;
  Function.prototype.apply = function (t, a) {
    try { return FC.call(FA, this, t, a); }
    catch (e) { if (!inApply) { inApply = true; try { out('EXC ' + desc(e) + ' ' + String(e && e.message).slice(0, 120) + ' @' + String(this && this.name)); } finally { inApply = false; } } throw e; }
  };
  var RH = Reflect.has, RG = Reflect.get;
  Reflect.has = function (o, k) { var r = RH(o, k); out('HAS ' + desc(o) + ' ' + String(k) + ' = ' + r); return r; };
  Reflect.get = function (o, k, rc) { var r = arguments.length > 2 ? RG(o, k, rc) : RG(o, k); out('GET ' + desc(o) + ' ' + String(k) + ' = ' + desc(r)); return r; };
  (function () {
    var X = XMLHttpRequest.prototype, oo = X.open, os = X.send, oh = X.setRequestHeader;
    X.open = function (m, u) { this.__u = String(u); this.__h = []; return oo.apply(this, arguments); };
    X.setRequestHeader = function (k, v) { (this.__h = this.__h || []).push(k + ': ' + v); return oh.apply(this, arguments); };
    X.send = function (b) {
      var x = this;
      if (/hcaptcha\.com\/(getcaptcha|checksiteconfig|checkcaptcha)/.test(x.__u || '')) {
        out('XHR ' + x.__u.slice(0, 160) + ' cred=' + x.withCredentials + ' type=' + x.responseType + ' hdrs=' + JSON.stringify(x.__h) + ' body=' + (b && (b.byteLength || b.length || b.size)));
        x.addEventListener('loadend', function () { var r = ''; try { r = x.responseType === '' || x.responseType === 'text' ? x.responseText : x.responseType === 'json' ? JSON.stringify(x.response) : '[' + x.responseType + ' ' + (x.response && x.response.byteLength) + '] ' + (x.response && x.response.byteLength < 2000 ? new TextDecoder().decode(x.response) : ''); } catch (e) { r = 'ERR ' + e; } out('XHRDONE ' + x.status + ' ' + String(r).slice(0, 1500)); });
      }
      return os.apply(this, arguments);
    };
  })();
  var oi = W.instantiate, ois = W.instantiateStreaming, OI = W.Instance;
  W.instantiate = function (b, imp) { return oi.call(W, b, wrap(imp)).then(grab); };
  if (ois) W.instantiateStreaming = function (b, imp) { return ois.call(W, b, wrap(imp)).then(grab); };
  var NI = function Instance(m, imp) { return grab(new OI(m, wrap(imp))); };
  NI.prototype = OI.prototype;
  W.Instance = NI;
})();
