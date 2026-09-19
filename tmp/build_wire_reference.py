from pathlib import Path
import re
r=Path(__file__).resolve().parents[1]
d=r/'tmp/publish_wire_test'; d.mkdir(exist_ok=True)
classes=['RuntimeEconomyBuildingStore','RuntimeEconomyFamilyStore','RuntimeEconomyTradeEscrowStore']
domains=['building','family','trade_escrow']
src='\n'.join(f'#include "runtime_economy_{x}_store.h"' for x in domains)+'''\n#include <cstdio>
#include <cstdint>
template<class T> bool check(const T &s) {
 std::vector<uint8_t> wire; s.append_wire(wire);
 uint64_t h=1469598103934665603ull, m=(0x123456789abcdef0ull ^ wire.size())*1099511628211ull;
 for (uint8_t b:wire) {h=(h^b)*1099511628211ull; m=(m^b)*1099511628211ull;}
 if(h!=s.wire_content_hash()) return false;
#ifndef REFERENCE
 if(m!=s.mix_wire_hash(0x123456789abcdef0ull)) return false;
#endif
 std::printf("%zu %llu %llu\\n",wire.size(),(unsigned long long)h,(unsigned long long)m); return true;
}
int main(){
'''
for dom,cls in zip(domains,classes):
    header=(r/f'gdext/src/runtime_economy_{dom}_store.h').read_text(encoding='utf-8')
    cols=re.findall(r'std::vector<([^>]+)>\s+(\w+)\s*;',header)
    src+='{ pk::'+cls+' s; if(!check(s))return 1;\n'
    src+='for(int scenario=0;scenario<3;++scenario){\n'
    for typ,name in cols:
        src+=f's.{name}.resize(16); for(size_t i=0;i<16;++i) s.{name}[i]=static_cast<{typ}>(scenario==0?0:(scenario==1?i+1:~uint64_t(i*987654321)));\n'
        if 'begin' in name:src+=f'for(auto &v:s.{name})v=0;\n'
        if 'count' in name:src+=f'for(auto &v:s.{name})v=1;\n'
    src+='if(!check(s))return 2; } }\n'
src+='return 0;}\n'
(d/'test.cpp').write_text(src)
scons='''from pathlib import Path
r=Path(Dir('.').abspath).parents[1]
d=r/'tmp/publish_wire_test'
ref=ARGUMENTS.get('reference','0')=='1'
source=r/'tmp/publish_optimization_originals' if ref else r/'gdext/src'
name='reference' if ref else 'optimized'
SConsignFile(str(d/(name+'.sconsign')))
env=Environment()
env.Append(CPPPATH=[str(source),str(r/'gdext/src')],CCFLAGS=['/std:c++17','/EHsc','/O2','/utf-8'])
if ref:env.Append(CPPDEFINES=['REFERENCE'])
files=['runtime_economy_building_store.cpp','runtime_economy_family_store.cpp','runtime_economy_trade_escrow_store.cpp']
objects=[env.Object(str(d/(name+'_'+f+'.obj')),str(source/f)) for f in files]
objects.append(env.Object(str(d/(name+'_test.obj')),str(d/'test.cpp')))
Default(env.Program(str(d/name),objects))
'''
(d/'SConstruct').write_text(scons)
