const fs = require('fs'); const path = require('path');
const SC = require('D:/Godot/ProjectKeynes/Project.Keynes/tools/supply-chain-explorer/parser.js');
const ROOT = 'D:/Godot/ProjectKeynes/Project.Keynes';
const DIRS = ['Project/project-keynes/data/economy/buildings','Project/project-keynes/data/goods','Project/project-keynes/data/resources','Project/project-keynes/data/economy/professions'];
const TAX = 'Project/project-keynes/scripts/economy/technology_taxonomy.gd';
function walk(d){let o=[];let e;try{e=fs.readdirSync(d,{withFileTypes:true});}catch(_){return o;}for(const x of e){const p=path.join(d,x.name);if(x.isDirectory())o.push(...walk(p));else if(x.name.endsWith('.tres'))o.push(p);}return o;}
const data={buildings:[],goods:[],resources:[],professions:[]};
for(const rel of DIRS)for(const f of walk(path.join(ROOT,rel))){const r=SC.classifyAndParse(f,fs.readFileSync(f,'utf8'));if(r&&r.record)data[r.type+'s'].push(r.record);}
const model=SC.buildModel({...data,eras:SC.parseEraFile(fs.readFileSync(path.join(ROOT,TAX),'utf8'))});
// 找出所有声明了 categoryEdge 的消费建筑
const catBuildings = model.buildings.filter(b=>(b.consumedCategories||[]).length>0);
console.log('声明类目消费的建筑数:', catBuildings.length);
let allWired=true;
for(const b of catBuildings){
  for(const cat of b.consumedCategories){
    const members = model.goodsByCategory[cat]||[];
    for(const gid of members){
      const g=model.goodById[gid];
      if(!g){continue;}
      if(!g.consumedBy.includes(b.id)){allWired=false;console.log('缺失反向边',gid,'<-',b.id,'(类目',cat+')');}
      if(!g._consumedByCat.has(b.id)){allWired=false;console.log('缺失 _consumedByCat',gid,'<-',b.id);}
    }
  }
}
console.log('反向边全部连通:', allWired);
// 统计每类目被多少建筑消费
const catConsumerCount={};
catBuildings.forEach(b=>(b.consumedCategories||[]).forEach(c=>catConsumerCount[c]=(catConsumerCount[c]||0)+1));
console.log('各类目被声明消费的建筑数:', JSON.stringify(catConsumerCount,null,0));
process.exit(allWired?0:1);
