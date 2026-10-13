/* Replay a recording made by hsw-record.js through whatever WebAssembly
 * this runs on: V8 (node hsw-replay.js REC) or the engine's own -- wasm3
 * behind vita_polyfill.js -- in tools/wasm-fuzz/harness.c
 * (tools/hcaptcha/replay.sh does both). The module gets exactly the inputs
 * it had when recorded: the same calls in the same order, every import
 * answering what it answered, every byte JavaScript wrote into memory
 * written at the same point. The module's side is then checked against
 * the record: the import it calls next, with which arguments, the bytes
 * behind each (pointer, length) argument pair, each call's result, and a
 * hash of all of memory after each call. Prints the first divergence. */
function hswReplay(text, WA, log, onImport) {
  var lines = text.split('\n'), mods = {}, inst = null, i;
  for (i = 0; i < lines.length; i++) {
    var l = lines[i];
    if (l.charAt(0) === 'M' && l.charAt(1) === ' ') { var sp = l.indexOf(' ', 2); mods[l.slice(2, sp)] = l.slice(sp + 1); }
  }
  /* the instance with the most calls: hsw (instance 0 is a feature probe) */
  var count = {};
  for (i = 0; i < lines.length; i++) { var m = /^(\d+) X /.exec(lines[i]); if (m) count[m[1]] = (count[m[1]] || 0) + 1; }
  Object.keys(count).forEach(function (k) { if (inst === null || count[k] > count[inst]) inst = k; });
  var modId = null;
  for (i = 0; i < lines.length; i++) { var mm = new RegExp('^' + inst + ' INSTANCE (\\S+)').exec(lines[i]); if (mm) modId = mm[1]; }
  if (inst === null || !mods[modId]) return 'replay: no instance with calls and known module bytes';
  function unhex(h) { var u = new Uint8Array(h.length >> 1); for (var j = 0; j < u.length; j++) u[j] = parseInt(h.substr(j * 2, 2), 16); return u; }
  /* events of that instance, each with the memory writes that follow it */
  var evs = [], cur = null;
  for (i = 0; i < lines.length; i++) {
    var s = lines[i];
    if (s.charAt(0) === 'W' && s.charAt(1) === ' ') { if (cur) { var p = s.indexOf(' ', 2); cur.w.push([+s.slice(2, p), s.slice(p + 1)]); } continue; }
    if (s.charAt(0) === 'G' && s.charAt(1) === ' ') { if (cur) cur.g = +s.slice(2); continue; }
    var sp1 = s.indexOf(' ');
    if (s.slice(0, sp1) !== inst) { cur = null; continue; }
    cur = { k: s.charAt(sp1 + 1), t: s.slice(sp1 + 3), w: [], g: 0, line: i + 1 };
    if ('XRIiEt'.indexOf(cur.k) < 0 || s.charAt(sp1 + 2) !== ' ') { cur = null; continue; }
    evs.push(cur);
  }
  function val(t) {
    var c = t.charAt(0), r = t.slice(1);
    if (c === 'n') return r === '-0' ? -0 : Number(r);
    if (c === 'b') return BigInt(r);
    if (c === 'u') return undefined;
    if (c === 'N') return null;
    if (c === 'T') return true;
    if (c === 'F') return false;
    if (c === 's') return JSON.parse(r);
    return Number(r);
  }
  function V(v) {
    var t = typeof v;
    if (t === 'number') return Object.is(v, -0) ? 'n-0' : 'n' + v;
    if (t === 'bigint') return 'b' + v;
    if (t === 'undefined') return 'u';
    return 'o' + String(v);
  }
  function hb(u, a, b) { var h = 0x811c9dc5; for (var j = a; j < b; j++) h = Math.imul(h ^ u[j], 16777619); return (h >>> 0).toString(16); }
  function hm(m) { var w = new Int32Array(m.buffer), h = 0; for (var j = 0; j < w.length; j++) h = (Math.imul(h, 31) + w[j]) | 0; return w.length + ':' + (h >>> 0).toString(16); }
  var mem = null, pos = 0, nx = 0, ni = 0, bad = null;
  function apply(e) {
    if (e.g) { var have = mem.buffer.byteLength; if (e.g > have) mem.grow((e.g - have) / 65536); }
    var u = new Uint8Array(mem.buffer);
    for (var j = 0; j < e.w.length; j++) u.set(unhex(e.w[j][1]), e.w[j][0]);
  }
  function P(args) {
    var u = new Uint8Array(mem.buffer), n = u.length, r = '';
    for (var j = 0; j + 1 < args.length; j++) {
      var p = args[j], l = args[j + 1];
      if (typeof p === 'number' && typeof l === 'number' && p >= 0 && l > 0 && l <= 1048576 && (p | 0) === p && (l | 0) === l && p + l <= n)
        r += ' P' + j + '=' + hb(u, p, p + l);
    }
    return r;
  }
  function ctx(at) {
    var out = [];
    for (var j = Math.max(0, at - 4); j <= at && j < evs.length; j++) out.push('    record line ' + evs[j].line + ': ' + evs[j].k + ' ' + evs[j].t.slice(0, 160));
    return out.join('\n');
  }
  function diverge(what) { if (!bad) bad = 'replay: DIVERGES at event ' + pos + ' (export call ' + nx + ', import call ' + ni + '): ' + what + '\n' + ctx(pos); throw new Error('diverged'); }
  var bytes = unhex(mods[modId]), module = new WA.Module(bytes), imports = {};
  WA.Module.imports(module).forEach(function (d) {
    if (!imports[d.module]) imports[d.module] = {};
    if (d.kind !== 'function') { log('replay: import ' + d.module + '.' + d.name + ' is a ' + d.kind + ' (not replayed)'); return; }
    var name = d.module + '.' + d.name;
    imports[d.module][d.name] = function () {
      var e = evs[pos], a = [];
      for (var j = 0; j < arguments.length; j++) a.push(V(arguments[j]));
      var got = 'I ' + name + ' ' + a.join(' ') + ' |' + P(arguments);
      if (!e || e.k !== 'I') diverge('the module calls ' + got.slice(2, 200) + ' where the record has ' + (e ? e.k + ' ' + e.t.slice(0, 120) : 'nothing more'));
      if ('I ' + e.t !== got) diverge('import call\n    replay: ' + got.slice(0, 300) + '\n    record: I ' + e.t.slice(0, 300));
      if (onImport) onImport(ni, name, arguments, new Uint8Array(mem.buffer), evs[pos + 1]);
      ni++; pos++;
      var r = evs[pos];
      if (!r || (r.k !== 'i' && r.k !== 't')) diverge('record has no result for this import');
      pos++;
      apply(r);
      if (r.k === 't') throw new Error(JSON.parse(r.t));
      return val(r.t);
    };
  });
  var instance = new WA.Instance(module, imports), ex = instance.exports;
  Object.keys(ex).forEach(function (k) { if (ex[k] instanceof WA.Memory) mem = ex[k]; });
  if (!mem) return 'replay: hsw exports no memory';
  var t0 = Date.now();
  try {
    while (pos < evs.length) {
      var e = evs[pos];
      if (e.k !== 'X') diverge('the record has ' + e.k + ' ' + e.t.slice(0, 120) + ' where the replay is between calls');
      var sp2 = e.t.indexOf(' '), fname = sp2 < 0 ? e.t : e.t.slice(0, sp2), args = sp2 < 0 ? [] : e.t.slice(sp2 + 1).split(' ').filter(Boolean).map(val);
      apply(e); pos++; nx++;
      var f = ex[fname], r, thrown = null;
      if (typeof f !== 'function') diverge('no export ' + fname);
      try { r = f.apply(null, args); } catch (x) { if (bad) throw x; thrown = x; }
      var q = evs[pos];
      if (!q || (q.k !== 'R' && q.k !== 'E')) diverge('export ' + fname + ' returned' + (thrown ? ' (threw ' + thrown + ')' : ' ' + V(r)) + '; the record has ' + (q ? q.k + ' ' + q.t.slice(0, 120) : 'nothing') + ' next (the module made fewer import calls)');
      if (q.k === 'E') { if (!thrown) diverge('export ' + fname + ' returned ' + V(r) + '; recorded: threw ' + q.t); }
      else {
        if (thrown) diverge('export ' + fname + ' threw ' + thrown + '; recorded: ' + q.t);
        var bar = q.t.indexOf(' | H'), want = q.t.slice(0, bar), wh = q.t.slice(bar + 4), gh = hm(mem);
        if (V(r) !== want) diverge('export ' + fname + ' returned ' + V(r) + ', recorded ' + want);
        if (gh !== wh) diverge('memory after export ' + fname + ': hash ' + gh + ', recorded ' + wh);
      }
      pos++;
    }
  } catch (x) {
    if (!bad) return 'replay: harness error at event ' + pos + ': ' + x + '\n' + ctx(pos);
    return bad;
  }
  return 'replay: IDENTICAL -- ' + nx + ' export calls, ' + ni + ' import calls, every argument, result, memory hash (' + (Date.now() - t0) + ' ms)';
}
if (typeof module === 'object' && typeof require === 'function' && require.main === module) {
  console.log(hswReplay(require('fs').readFileSync(process.argv[2], 'utf8'), WebAssembly, console.log));
} else if (typeof REC === 'string') {
  print(hswReplay(REC, WebAssembly, print));
}
