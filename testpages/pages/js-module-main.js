/* testpages/pages/JS-module.html: a module script with a static import
 * chain and a dynamic import (patches 71, 72). */
import { depValue } from "./js-module-dep.js";

var passed = 0, total = 6, done = {};
function pass(n, what) {
	var p = document.getElementById("r" + n);
	if (!p || done[n]) return;
	done[n] = true;
	passed++;
	p.className = "pass";
	if (what) p.textContent = what;
	var s = document.getElementById("sum");
	s.textContent = "MODULES: " + passed + "/" + total + " passed";
	s.className = passed === total ? "pass" : "wait";
	document.title = "JS module " + passed + "/" + total;
}
window.__modPass = pass;
if (document.getElementById("last") && document.getElementById("r6"))
	pass(1, "1 module sees the whole document (charset restart): PASS");
if (depValue() === "dep+leaf")
	pass(2, "2 static import chain (main, dep, leaf): PASS");
if (document.getElementById("last"))
	pass(3, "3 module runs deferred (after the body is parsed): PASS");
import("./js-module-lazy.js").then(function (m) {
	if (m["default"]() === "lazy") pass(4, "4 dynamic import(): PASS");
}, function (e) {
	document.getElementById("r4").textContent = "4 dynamic import(): FAILED " + e;
});
if (document.getElementById("r5").textContent.indexOf(": leaf") > 0)
	pass(5, "5 inline module import: PASS");
var t = document.getElementById("last").textContent;
if (t.length === 4 && t.charCodeAt(3) === 0xe9)
	pass(6, "6 UTF-8 text after the late charset (café = 4 chars): PASS");
else
	document.getElementById("r6").textContent += " got " + t.length + " chars";
