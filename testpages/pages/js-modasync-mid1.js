// JS-module-async.html: level 2 of the graph
import { leaf1, double1 } from "./js-modasync-leaf1.js";
import { leaf2 } from "./js-modasync-leaf2.js";
import { leaf3 } from "./js-modasync-leaf3.js";
export const mid1 = double1(leaf1) + leaf2 + leaf3;
