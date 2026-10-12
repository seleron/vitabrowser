function bytes(b64) { var m = {}, chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; var out = [], buf = 0, bits = 0;
  for (var i = 0; i < b64.length; i++) { var c = chars.indexOf(b64[i]); if (c < 0) continue; buf = (buf << 6) | c; bits += 6; if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 255); } }
  return new Uint8Array(out); }
var fails = 0;
function check(name, ok) { if (!ok) { fails++; print('FAIL ' + name); } }
var WA = WebAssembly, B = bytes(W_basic), I = bytes(W_imports), M = bytes(W_memimport);
/* functional */
var e = new WA.Instance(new WA.Module(B), {}).exports;
check('add', e.add(2, 3) === 5);
check('trap', (function () { try { e.trap(); } catch (x) { return x instanceof WA.RuntimeError; } })());
var v = new Uint8Array(e.memory.buffer); e.grow(1); check('detach', v.byteLength === 0 && e.memory.buffer.byteLength === 131072);
var inst2; inst2 = new WA.Instance(new WA.Module(I), { env: { cb: function (x) { return inst2.exports.inner(x); }, thrower: function () { throw 7; } } });
check('reenter', inst2.exports.callcb(5) === 11);
check('throw', (function () { try { inst2.exports.callthrow(); } catch (x) { return x === 7; } })());
var mem = new WA.Memory({ initial: 1 }), mv = new Uint8Array(mem.buffer); mv[5] = 9;
var i3 = new WA.Instance(new WA.Module(M), { env: { mem: mem } }); check('memimport', i3.exports.peek(5) === 9 && i3.exports.peek(100) === 42);
check('memimport twice LinkError', (function () { try { new WA.Instance(new WA.Module(M), { env: { mem: mem } }); } catch (x) { return x instanceof WA.LinkError; } })());
/* lifetimes: buffers and functions outliving their instances */
var keep = [];
for (var r = 0; r < 200; r++) {
  var x = new WA.Instance(new WA.Module(B), {}).exports;
  if (r % 3 === 0) keep.push(x.memory.buffer);
  if (r % 5 === 0) keep.push(x.add);
  if (r % 7 === 0) { var bb = x.memory.buffer; x.grow(1); keep.push(bb); }
  if (r % 11 === 0) keep.push(x.tbl);
  if (r % 13 === 0) keep.push(x.memory);
  if (r % 20 === 0) gc();
}
gc();
keep.forEach(function (k) { if (typeof k === 'function') k(1, 2); else if (k instanceof WA.Table) k.get(0)(); else if (k instanceof WA.Memory) { k.grow(1); new Uint8Array(k.buffer)[0] = 1; } else if (k instanceof ArrayBuffer) k.byteLength; });
keep = null; gc();
/* stop from a slice */
if (globalThis.STOP) check('stopped', (function () { try { e.spin(2000000000); return false; } catch (x) { return x instanceof WA.RuntimeError && /interrupted/.test(x.message); } })());
/* fuzz: mutated modules, random calls */
var seed = SEED;
function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
function ri(n) { return Math.floor(rnd() * n); }
var vals = [0, 1, -1, 2147483647, -2147483648, NaN, Infinity, 1e300, 'x', undefined, null, {}, 3.5];
var ok = 0, made = 0;
for (var it = 0; it < 3000; it++) {
  var src = [B, I, M][ri(3)], b = new Uint8Array(src);
  var muts = ri(4);
  for (var q = 0; q < muts; q++) b[8 + ri(b.length - 8)] = ri(256);
  if (ri(10) === 0) b = b.slice(0, ri(b.length));
  try {
    var mod = new WA.Module(b); made++;
    WA.Module.exports(mod); WA.Module.imports(mod);
    var imp = { env: { cb: function (x) { return ri(3) ? x : (function () { throw 1; })(); }, thrower: function () { throw 2; }, mem: new WA.Memory({ initial: 1 }) } };
    var ex = new WA.Instance(mod, imp).exports;
    for (var name in ex) {
      var f = ex[name];
      try {
        if (typeof f === 'function') { if (name !== 'spin') f(vals[ri(vals.length)], vals[ri(vals.length)]); else f(ri(1000)); }
        else if (f instanceof WA.Memory) { if (ri(4) === 0) f.grow(ri(3)); new Uint8Array(f.buffer); }
        else if (f instanceof WA.Global) { f.value; try { f.value = vals[ri(vals.length)]; } catch (z) {} }
        else if (f instanceof WA.Table) { f.length; try { var tf = f.get(ri(4)); if (tf) tf(); } catch (z) {} }
        ok++;
      } catch (z) {}
    }
  } catch (z) { }
  if (it % 100 === 0) gc();
}
print('fuzz: ' + made + ' modules made, ' + ok + ' calls returned; fails ' + fails);
