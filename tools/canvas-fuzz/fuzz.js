var seed = 12345;
function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
function ri(n) { return Math.floor(rnd() * n); }
function num() {
	var k = ri(12);
	if (k === 0) return NaN; if (k === 1) return Infinity; if (k === 2) return -1e12;
	if (k === 3) return 1e12; if (k === 4) return -ri(50); if (k === 5) return rnd() * 0.01;
	return rnd() * 300 - 50;
}
function pts(n) { var a = new Float64Array(n * 2); for (var i = 0; i < a.length; i++) a[i] = num(); return a; }
function counts(n) {
	var c = [], left = n;
	while (left > 0) { var k = 1 + ri(left); c.push(k); left -= k; }
	if (ri(10) === 0) c.push(5);	/* more than there are */
	if (ri(10) === 0) c[0] = -3;
	return new Int32Array(c);
}
var hs = [];
for (var i = 0; i < 6; i++) hs.push(__cv.create(null, ri(3) ? ri(200) : ri(3) * 3000, ri(3) ? ri(150) : 0));
function stops() { var n = ri(4) * 5 + (ri(5) === 0 ? 3 : 0); var a = new Float64Array(n); for (var i = 0; i < n; i++) a[i] = ri(3) ? rnd() * 300 - 20 : num(); return a; }
function paint() {
	var t = ri(6), m = [num(), num(), num(), num(), num(), num()];
	if (ri(3)) m = [rnd() * 2, rnd() - 0.5, rnd() - 0.5, rnd() * 2, rnd() * 20, rnd() * 20];
	switch (t) {
	case 0: return [0, ri(300) - 20, ri(256), ri(256), rnd() * 1.5 - 0.2];
	case 1: return [1].concat(m, [num(), num(), num(), num(), stops()]);
	case 2: return [2].concat(m, [num(), num(), Math.abs(num()), num(), num(), Math.abs(num()), stops()]);
	case 3: return [3].concat(m, [num(), num(), num(), stops()]);
	case 4: return [4].concat(m, [hs[ri(hs.length)], num(), num(), num(), num(), ri(2), ri(2), ri(2)]);
	default: return ri(2) ? null : [9];
	}
}
var ops = 0;
for (var it = 0; it < 6000; it++) {
	var h = hs[ri(hs.length)], k = ri(13), n = 1 + ri(ri(4) === 0 ? 60 : 8);
	try {
		switch (k) {
		case 0: __cv.fill(h, pts(n), counts(n), ri(2) === 1, paint(), rnd() * 1.2, ri(17) - 1); break;
		case 1: __cv.stroke(h, pts(n), counts(n), new Uint8Array(ri(2) ? 40 : 0).fill(ri(2)), ri(4) === 0 ? num() : rnd() * 30, ri(4), ri(4), num(), paint(), rnd(), ri(16)); break;
		case 2: __cv.clip(h, pts(n), counts(n), ri(2) === 1); break;
		case 3: __cv.save(h); break;
		case 4: __cv.restore(h); break;
		case 5: __cv.text(h, 'Helloé中' + ri(100), num(), ri(5) - 1, ri(2), ri(2), num(), num(), paint(), rnd(), ri(16)); break;
		case 6: if (ri(4) === 0) __cv.resize(h, ri(250), ri(250)); break;
		case 7: var w = ri(60) - 5, hh = ri(60) - 5; if (w > 0 && hh > 0) __cv.get(h, ri(300) - 100, ri(300) - 100, w, hh); break;
		case 8: var iw = 1 + ri(30), ih = 1 + ri(30), d = new Uint8ClampedArray(iw * ih * 4 - (ri(5) === 0 ? 4 : 0)); __cv.put(h, d, iw, ih, ri(300) - 100, ri(300) - 100, num(), num(), num(), num()); break;
		case 9: if (ri(20) === 0) __cv.png(h, ri(2) === 1); break;
		case 10: __cv.imgsize(h); __cv.measure('abc', num(), 0, 0, 0); break;
		case 11: __cv.reset(h); break;
		case 12: __cv.fill(h, pts(n), [1, 2], false, paint(), 1, 0); __cv.fill({}, pts(2), counts(2), false, paint(), 1, 0); break;
		}
		ops++;
	} catch (e) { if (!(e instanceof RangeError)) throw e; }
}
'ok ' + ops;
