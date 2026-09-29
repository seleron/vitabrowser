// JS-module-dedupe.html: the static graph
import { v, token } from "./slow/js-moddup-shared.js";
import { sv } from "./js-moddup-sa.js";
const M = window.moddup;
M.evals.a = (M.evals.a || 0) + 1;
M.a = v + sv;
M.tokA = token;
export const a = v + sv;
