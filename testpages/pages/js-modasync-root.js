// JS-module-async.html: the root import() loads (9 modules, 3 levels)
import { mid1 } from "./js-modasync-mid1.js";
import { mid2 } from "./js-modasync-mid2.js";
export const total = mid1 + mid2;
