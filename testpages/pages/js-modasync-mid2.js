// JS-module-async.html: level 2 of the graph
import { leaf4 } from "./js-modasync-leaf4.js";
import { leaf5 } from "./js-modasync-leaf5.js";
import { leaf6, double6 } from "./js-modasync-leaf6.js";
export const mid2 = leaf4 + leaf5 + double6(leaf6);
