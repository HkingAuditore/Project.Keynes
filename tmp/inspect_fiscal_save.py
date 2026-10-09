import struct, json
from pathlib import Path
from compression import zstd
p = Path('C:/Users/HkingAuditore/AppData/Roaming/Godot/app_userdata/ProjectKeynes/saves/autosave.pksv').read_bytes()
n = struct.unpack_from('<I',p,8)[0]
h = json.loads(p[12:12+n])
entry = next(s for s in h['sections'] if s['id']=='ecp2')
data = zstd.decompress(p[12+n+entry['offset']:12+n+entry['offset']+entry['length']])
cursor = 0
count = 0
while True:
    cursor = data.find(b'PKEC',cursor)
    if cursor < 0: break
    magic,schema,section,records,size = struct.unpack_from('<IHHII',data,cursor)
    if section==30 and schema==55 and size==records*176:
        for j in range(records):
            offset = cursor+16+j*176
            rid,tid,ch,cg,pg,cpg,day,seq,ci,cs,op,code,state,accepted,r0,r1,rq,rc,cq,cc = struct.unpack_from('<QQQQQQqQIiHBBBBHqqqq',data,offset)
            if cq>rq or cc>rc or min(rq,rc,cq,cc)<0:
                print(dict(request=rid,day=day,op=op,code=code,state=state,accepted=accepted,requested_quantity=rq,requested_cash=rc,committed_quantity=cq,committed_cash=cc))
                count+=1
                if count>=12: raise SystemExit
    cursor+=4
