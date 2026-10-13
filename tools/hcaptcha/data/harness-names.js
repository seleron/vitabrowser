/* the names Chromium's recording harness puts on window, so both lists match */
(function () { if (!/hcaptcha\.com$/.test(location.host)) return;
  ['__hswRec', '__playwright__binding__', '__playwright__binding__controller__'].forEach(function (n) {
    Object.defineProperty(window, n, { value: function __hswStandIn() {}, writable: true, configurable: true, enumerable: false }); }); })();
