/* give Chromium the engine's performance.now(): exact tenths of a ms */
(function () { var P = Object.getPrototypeOf(performance), d = Object.getOwnPropertyDescriptor(P, 'now'), f = d.value;
  Object.defineProperty(P, 'now', { value: function now() { return Math.round(f.call(this) * 10) / 10; }, writable: true, enumerable: true, configurable: true }); })();
