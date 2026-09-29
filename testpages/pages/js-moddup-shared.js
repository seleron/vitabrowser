// JS-module-dedupe.html: the leaf everyone imports (served via /slow/)
const M = window.moddup;
M.evals.shared = (M.evals.shared || 0) + 1;
export const v = 1;
export const token = {};
