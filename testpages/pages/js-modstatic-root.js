// JS-module-static-async.html: the external module graph (root -> 2 mids
// -> leaves, one of them served after 1 s)
import { mid1 } from "./js-modstatic-mid1.js";
import { mid2 } from "./js-modstatic-mid2.js";
const S = window.modstatic;
S.ext = mid1 + mid2;
S.order.push('ext');
