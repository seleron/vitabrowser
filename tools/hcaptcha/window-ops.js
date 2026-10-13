/* Every function-valued own property of window, as "name:length:enumerable:
 * name-if-different" -- evaluated in Chromium (and in the simulator with
 * VITA_SIM_INJECT or an eval) to make the WebIDL table patch 269 carries in
 * vita_polyfill.js: Chromium's length for each name both have, ECMAScript
 * intrinsics left out. Usage: page.evaluate(<this file>) in Playwright. */
(function () {
  var r = [];
  Object.getOwnPropertyNames(window).sort().forEach(function (k) {
    var d = Object.getOwnPropertyDescriptor(window, k);
    if (!d || !('value' in d) || typeof d.value !== 'function') return;
    r.push(k + ':' + d.value.length + ':' + (d.enumerable ? 'E' : '-') + ':' + (d.value.name === k ? '' : d.value.name));
  });
  return r.join(' ');
})()
