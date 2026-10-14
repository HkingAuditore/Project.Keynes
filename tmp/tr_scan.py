import json,sys
p=r'C:\Users\hkinghuang\.cursor\projects\d-Godot-ProjectKeynes\agent-transcripts\dc540480-9e1c-4f04-a928-82a37219ea39\dc540480-9e1c-4f04-a928-82a37219ea39.jsonl'
lines=open(p,encoding='utf-8').read().splitlines()
print(len(lines))
for i,l in enumerate(lines[880:],start=881):
    try: o=json.loads(l)
    except: continue
    role=o.get('role')
    c=o.get('message',{}).get('content',[])
    for b in c if isinstance(c,list) else []:
        if b.get('type')=='text':
            t=b['text']
            if role=='user' or 'AskQuestion' in t or len(t)>600:
                print('---',i,role,t[:700].replace('\n',' '))
        elif b.get('type')=='tool_use' and b.get('name')=='AskQuestion':
            print('---',i,'ASK',json.dumps(b['input'],ensure_ascii=False)[:600])
