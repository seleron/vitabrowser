// node v8run.js mod.wasm calls.json i   -> one line per call
const fs=require('fs'), zlib=require('zlib');
const [,,wf,cf,ix]=process.argv; const C=JSON.parse(fs.readFileSync(cf)); const c=C.calls[+ix];
const imp={}; for (const [m,n,k] of C.imports){ (imp[m]=imp[m]||{})[n]=()=>0; }
const inst=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wf)),imp);
const mem=Object.values(inst.exports).find(x=>x instanceof WebAssembly.Memory);
const f32=new Float32Array(1), u32=new Uint32Array(f32.buffer), f64=new Float64Array(1), u64=new BigUint64Array(f64.buffer);
function fmt(t,v){ if(t===0x7f) return String(v|0); if(t===0x7e) return BigInt.asIntN(64,v).toString();
  if(t===0x7d){f32[0]=v; return (v!==v?'nan':'f32:'+u32[0].toString(16));} f64[0]=v; return (v!==v?'nan':'f64:'+u64[0].toString(16)); }
function trap(e){ const m=String(e.message||e);
  for (const [k,re] of [['oob',/out of bounds/],['unreach',/unreachable/],['div0',/divide by zero/],['ovf',/integer overflow|divide result unrepresentable/],['conv',/conver|float unrepresentable/],['stack',/stack/]]) if(re.test(m)) return k; return 'other:'+m.slice(0,40); }
const out=[];
for (const a of c.args){
  const args=a.map((v,i)=>c.params[i]===0x7e?BigInt(v):v);
  let r; try { const x=inst.exports[c.name](...args); r='R '+(c.results.length===0?'-':c.results.length===1?fmt(c.results[0],x):x.map((y,i)=>fmt(c.results[i],y)).join(','));} catch(e){ r='T '+trap(e); }
  out.push(r+' M '+zlib.crc32(new Uint8Array(mem.buffer)).toString(16)+' P '+mem.buffer.byteLength);
}
console.log(out.join('\n'));
