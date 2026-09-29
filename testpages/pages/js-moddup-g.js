// JS-module-dedupe.html: a module script (twice on the page) importing f
import { fv } from "./js-moddup-f.js";
const M = window.moddup;
M.evals.g = (M.evals.g || 0) + 1;
M.order.push('g');
M.g = fv + 1;
