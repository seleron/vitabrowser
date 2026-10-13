/* clock probe: every performance.now() / Date.now() value read in hCaptcha's
 * frames, raw, with a call-site tag; logged in batches of 120 (the engine keeps console lines under 2 KB) */
(function () {
  if (!/hcaptcha\.com$/.test(location.host)) return;
  var fm = /frame=(\w+)/.exec(location.hash || ''), tag = (fm ? fm[1] : '-') + '.' + Math.random().toString(36).slice(2, 6);
  var buf = [], PN = performance.now, DN = Date.now, P = Object.getPrototypeOf(performance);
  function out() { if (buf.length) { console.log('TMREC ' + tag + ' ' + buf.join(' ')); buf = []; } }
  function wrapNow(f) { return function now() { var v = f.call(this); buf.push('p' + v); if (buf.length >= 120) out(); return v; }; }
  try {
    var d = Object.getOwnPropertyDescriptor(P, 'now');
    if (d && d.value) Object.defineProperty(P, 'now', { value: wrapNow(d.value), writable: true, enumerable: d.enumerable, configurable: true });
    else performance.now = wrapNow(PN);
  } catch (e) { performance.now = wrapNow(PN); }
  Date.now = function now() { var v = DN.call(Date); buf.push('d' + v); if (buf.length >= 120) out(); return v; };
  addEventListener('pagehide', out);
  /* flush on the getcaptcha request (the record must reach the log before the answer) */
  var os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () { out(); return os.apply(this, arguments); };
})();
