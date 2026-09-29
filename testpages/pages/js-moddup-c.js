// JS-module-dedupe.html: shares both leaves with b
import { v } from "./slow/js-moddup-shared.js";
import { dv } from "./slow/js-moddup-d.js";
const M = window.moddup;
M.evals.c = (M.evals.c || 0) + 1;
export const cv = v + dv + 20;
export { cv as v };
