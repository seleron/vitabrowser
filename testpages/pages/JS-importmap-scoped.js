/* JS-importmap.html: a module inside a scope -- its "vb-lib" is lib2
 * (patch 239). */
import { who } from 'vb-lib';
export const scopedWho = who;
