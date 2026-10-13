/* Logs (console "FPACC <host> <name>") each window global and each listed
 * prototype member a frame reads, once: tools/hcaptcha/chrome-demo.py
 * --log-access. The prototypes are captured before window is wrapped. */
(function () {
  var seen = new Set();
  var log = function (n) { if (!seen.has(n)) { seen.add(n); console.log('FPACC ' + location.host + ' ' + n); } };
  var skip = {window:1,self:1,top:1,parent:1,frames:1,globalThis:1,document:1,location:1,console:1,Object:1,Function:1,Array:1,Reflect:1,Proxy:1,Symbol:1,JSON:1,Math:1,Promise:1,Error:1,TypeError:1,String:1,Number:1,Boolean:1,Set:1,Map:1,WeakMap:1,Uint8Array:1,ArrayBuffer:1,setTimeout:1,clearTimeout:1,Date:1,RegExp:1,parseInt:1,WebAssembly:1};
  var protos = {Navigator: Navigator.prototype, Screen: Screen.prototype, Performance: Performance.prototype,
    Document: Document.prototype, HTMLCanvasElement: HTMLCanvasElement.prototype,
    CanvasRenderingContext2D: CanvasRenderingContext2D.prototype,
    WebGLRenderingContext: WebGLRenderingContext.prototype, WebGL2RenderingContext: WebGL2RenderingContext.prototype,
    Element: Element.prototype, HTMLElement: HTMLElement.prototype, Node: Node.prototype,
    Intl_DateTimeFormat: Intl.DateTimeFormat.prototype, Date: Date.prototype,
    BaseAudioContext: BaseAudioContext.prototype, OfflineAudioContext: OfflineAudioContext.prototype,
    AudioBuffer: AudioBuffer.prototype, NavigatorUAData: NavigatorUAData.prototype,
    Permissions: Permissions.prototype, MediaDevices: MediaDevices.prototype, FontFaceSet: FontFaceSet.prototype,
    ScreenOrientation: ScreenOrientation.prototype, NetworkInformation: NetworkInformation.prototype,
    StorageManager: StorageManager.prototype, SpeechSynthesis: SpeechSynthesis.prototype};
  Object.getOwnPropertyNames(window).forEach(function (k) {
    if (skip[k]) return;
    var d = Object.getOwnPropertyDescriptor(window, k);
    if (!d || !d.configurable) return;
    if ('value' in d) {
      var v = d.value;
      Object.defineProperty(window, k, {configurable: true, enumerable: d.enumerable,
        get: function () { log('window.' + k); return v; }, set: function (x) { v = x; }});
    } else if (d.get) {
      var g = d.get, s = d.set;
      Object.defineProperty(window, k, {configurable: true, enumerable: d.enumerable,
        get: function () { log('window.' + k); return g.call(this); }, set: s});
    }
  });
  Object.keys(protos).forEach(function (pn) {
    var P = protos[pn];
    Object.getOwnPropertyNames(P).forEach(function (k) {
      if (k === 'constructor') return;
      var d = Object.getOwnPropertyDescriptor(P, k);
      if (!d || !d.configurable) return;
      if (d.get) {
        var g = d.get;
        Object.defineProperty(P, k, {configurable: true, enumerable: d.enumerable,
          get: function () { log(pn + '.' + k); return g.call(this); }, set: d.set});
      } else if (typeof d.value === 'function') {
        var f = d.value;
        Object.defineProperty(P, k, {configurable: true, enumerable: d.enumerable, writable: true,
          value: function () { log(pn + '.' + k + '()'); return f.apply(this, arguments); }});
      }
    });
  });
})();
