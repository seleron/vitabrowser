// JS-module-dedupe.html: a module script that the next one (g) imports
const M = window.moddup;
M.evals.f = (M.evals.f || 0) + 1;
M.order.push('f');
export const fv = 7;
