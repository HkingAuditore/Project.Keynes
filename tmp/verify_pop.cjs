const fs=require('fs'),path=require('path');
const SC=require('D:/Godot/ProjectKeynes/Project.Keynes/tools/supply-chain-explorer/parser.js');
const ROOT='D:/Godot/ProjectKeynes/Project.Keynes';
const DIRS=['Project/project-keynes/data/economy/buildings','Project/project-keynes/data/goods','Project/project-keynes/data/resources','Project/project-keynes/data/economy/professions','Project/project-keynes/data/economy/consumption_plans'];
const TAX='Project/project-keynes/scripts/economy/technology_taxonomy.gd';
function walk(d){let o=[];let e;try{e=fs.readdirSync(d,{withFileTypes:true});}catch(_){return o;}for(const x of e){const p=path.join(d,x.name);if(x.isDirectory())o.push(...walk(p));else if(x.name.endsWith('.tres'))o.push(p);}return o;}
const data={buildings:[],goods:[],resources:[],professions:[],plans:[]};
for(const rel of DIRS)for(const f of walk(path.join(ROOT,rel))){const r=SC.classifyAndParse(f,fs.readFileSync(f,'utf8'));if(r&&r.record)data[r.type+'s'].push(r.record);}
const model=SC.buildModel({...data,eras:SC.parseEraFile(fs.readFileSync(path.join(ROOT,TAX),'utf8'))});
console.log('消费计划数:',model.plans.length);
model.plans.forEach(p=>console.log('  ',p.id,'→ 消费',p.consumes.length,'种物资, era=',p.eraPrimary));
const popGoods=model.goods.filter(g=>g.consumedByPop.length>0);
console.log('被居民消费的物资数:',popGoods.length);
const popOnly=model.diagnostics.popOnlyGoods;
console.log('仅被居民消费(无建筑消费)的物资数:',popOnly.length, popOnly.slice(0,12).map(g=>g.id).join(', '));
console.log('孤儿物资数(含人口后):',model.diagnostics.orphanGoods.length,'(之前约 36)');
// 抽查 survival_household 应消费 clothing
const surv=model.planById['survival_household'];
console.log('survival_household 消费 clothing?', surv.consumes.some(c=>c.good==='clothing'));
const cloth=model.goodById['clothing'];
console.log('clothing.consumedByPop=',cloth.consumedByPop, ' consumedBy(建筑)=', cloth.consumedBy.length);
