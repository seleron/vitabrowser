# gen.py in.wasm out.wasm calls.json (tools/hcaptcha/wasm-diff/run.sh)
# gen.py in.wasm out.wasm calls.json : export every function whose call tree is import-free
import sys, json, random
b=bytearray(open(sys.argv[1],'rb').read())
def U(p):
    r=s=0
    while True:
        x=b[p]; p+=1; r|=(x&0x7f)<<s; s+=7
        if x<0x80: return r,p
def S(p):
    r=s=0
    while True:
        x=b[p]; p+=1; r|=(x&0x7f)<<s; s+=7
        if x<0x80:
            if x&0x40: r-=(1<<s)
            return r,p
def leb(n):
    out=bytearray()
    while True:
        x=n&0x7f; n>>=7
        if n: out.append(x|0x80)
        else: out.append(x); return out
p=8; secs={}
while p<len(b):
    sid=b[p]; size,q=U(p+1); secs[sid]=(p,q,q+size); p=q+size
types=[]; p=secs[1][1]; n,p=U(p)
for i in range(n):
    p+=1; np_,p=U(p); ps=list(b[p:p+np_]); p+=np_; nr,p=U(p); rs=list(b[p:p+nr]); p+=nr; types.append((ps,rs))
p=secs[2][1]; n,p=U(p); nimpf=0; imports=[]
for i in range(n):
    l,p=U(p); mod=b[p:p+l].decode(); p+=l; l,p=U(p); nm=b[p:p+l].decode(); p+=l; k=b[p]; p+=1
    if k==0: t,p=U(p); nimpf+=1; imports.append((mod,nm,'func',types[t]))
    elif k==1: p+=1; f,p=U(p); _,p=U(p); p = U(p)[1] if f&1 else p; imports.append((mod,nm,'table',None))
    elif k==2: f,p=U(p); _,p=U(p); p = U(p)[1] if f&1 else p; imports.append((mod,nm,'memory',None))
    elif k==3: p+=2; imports.append((mod,nm,'global',None))
p=secs[3][1]; n,p=U(p); ftype=[]
for i in range(n): t,p=U(p); ftype.append(t)
p=secs[10][1]; n,p=U(p); info=[]
def bt(p):
    x=b[p]
    if x==0x40 or x in (0x7f,0x7e,0x7d,0x7c): return p+1
    return S(p)[1]
for i in range(n):
    sz,p=U(p); end=p+sz; nl,q=U(p)
    for j in range(nl): _,q=U(q); q+=1
    icalls=cnt=0; callees=set()
    while q<end:
        op=b[q]; q+=1; cnt+=1
        if op in (2,3,4): q=bt(q)
        elif op in (0x0c,0x0d,0x10,0x20,0x21,0x22,0x23,0x24,0x3f,0x40):
            v,q=U(q)
            if op==0x10: callees.add(v)
        elif op==0x0e:
            k,q=U(q)
            for _ in range(k+1): _,q=U(q)
        elif op==0x11: icalls+=1; _,q=U(q); _,q=U(q)
        elif 0x28<=op<=0x3e: _,q=U(q); _,q=U(q)
        elif op==0x41: _,q=S(q)
        elif op==0x42: _,q=S(q)
        elif op==0x43: q+=4
        elif op==0x44: q+=8
        elif op==0xfc: _,q=U(q)   # saturating truncs / bulk memory: sub-op (+ operands for bulk)
    info.append(dict(idx=nimpf+i, callees=callees, sig=types[ftype[i]], instrs=cnt, icalls=icalls))
    p=end
byidx={f['idx']:f for f in info}
pure={}
def isp(i, st=()):
    if i<nimpf: return False
    if i in pure: return pure[i]
    if i in st: return True
    f=byidx[i]; r = f['icalls']==0 and all(isp(c, st+(i,)) for c in f['callees'])
    pure[i]=r; return r
pick=[f for f in info if isp(f['idx']) and all(t in (0x7f,0x7e,0x7d,0x7c) for t in f['sig'][0]+f['sig'][1])]
print('imports', len(imports), [ (m,n,k) for m,n,k,_ in imports if k!='func'], 'funcs', len(info), 'pure', len(pick), file=sys.stderr)
p0,q0,e0=secs[7]; n,q=U(q0); body=bytearray(b[q:e0])
for f in pick:
    nm=('d_%d'%f['idx']).encode(); body+=leb(len(nm))+nm+bytes([0])+leb(f['idx'])
newsec=leb(n+len(pick))+body
open(sys.argv[2],'wb').write(b[:p0]+bytes([7])+leb(len(newsec))+newsec+b[e0:])
rnd=random.Random(1337)
def val(t):
    c=rnd.random()
    if t==0x7f: return rnd.choice([0,1,7,64,255]) if c<.3 else (rnd.randrange(1024,1<<20)&~7 if c<.7 else rnd.getrandbits(32)-(1<<31))
    if t==0x7e: return str(rnd.choice([0,1,-1,1<<40]) if c<.3 else rnd.getrandbits(64)-(1<<63))
    if t==0x7d: return rnd.choice([0.0,1.5,-2.25,3.4e38,1e-40]) if c<.5 else rnd.uniform(-1e6,1e6)
    return rnd.choice([0.0,1.5,-2.25,1e308,5e-324]) if c<.5 else rnd.uniform(-1e12,1e12)
calls=[dict(name='d_%d'%f['idx'], params=f['sig'][0], results=f['sig'][1], args=[[val(t) for t in f['sig'][0]] for _ in range(3)]) for f in pick]
json.dump(dict(imports=imports, calls=calls), open(sys.argv[3],'w'))
