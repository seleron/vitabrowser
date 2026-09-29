// JS-module-dedupe.html: import()ed early AND a <script type=module src>
import { v } from "./slow/js-moddup-shared.js";
const M = window.moddup;
M.evals.e = (M.evals.e || 0) + 1;
export const ev = v + 100;
