/* give Chromium the engine's timers: a timer with a delay waits for the next 16 ms frame */
(function () { var st = setTimeout, si = setInterval;
  function late(d) { d = +d || 0; return d > 0 ? Math.ceil((d + 1) / 16) * 16 : d; }
  window.setTimeout = function setTimeout(f, d) { var a = Array.prototype.slice.call(arguments); a[1] = late(d); return st.apply(this, a); };
  window.setInterval = function setInterval(f, d) { var a = Array.prototype.slice.call(arguments); a[1] = late(d); return si.apply(this, a); }; })();
