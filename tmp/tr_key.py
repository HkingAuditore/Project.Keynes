import json
p=r'C:\Users\hkinghuang\.cursor\projects\d-Godot-ProjectKeynes\agent-transcripts\dc540480-9e1c-4f04-a928-82a37219ea39\dc540480-9e1c-4f04-a928-82a37219ea39.jsonl'
lines=open(p,encoding='utf-8').read().splitlines()
out=open(r'tmp\tr_key.txt','w',encoding='utf-8')
for n in (902,965,1005,1073,1236,1355,1402):
    o=json.loads(lines[n-1])
    for b in o['message']['content']:
        if b.get('type')=='text':
            out.write(f'==== {n}\n'+b['text'][:5000]+'\n')
out.close()
