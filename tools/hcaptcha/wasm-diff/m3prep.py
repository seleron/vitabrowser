import json,sys
C=json.load(open(sys.argv[1])); T={0x7f:'i',0x7e:'I',0x7d:'f',0x7c:'d'}
with open(sys.argv[2],'w') as o:
    for c in C['calls']:
        o.write('#%s|%s|%s\n'%(c['name'],''.join(T[t] for t in c['params']) or '-',''.join(T[t] for t in c['results']) or '-'))
        for a in c['args']: o.write(' '.join(repr(float(x)) if c['params'][i] in (0x7d,0x7c) else str(x) for i,x in enumerate(a))+'\n')
with open(sys.argv[3],'w') as o:
    for m,n,k,_ in C['imports']: o.write('%s %s\n'%(m,n))
