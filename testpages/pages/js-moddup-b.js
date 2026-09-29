// JS-module-dedupe.html: imported twice at once, and again later
import { v, token } from "./slow/js-moddup-shared.js";
import { dv } from "./slow/js-moddup-d.js";
const M = window.moddup;
M.evals.b = (M.evals.b || 0) + 1;
export const tok = token;
export const v2 = v;
export { dv };
export const vv = v + dv + 10;
export { vv as v };
