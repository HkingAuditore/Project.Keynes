from pathlib import Path
import re,shutil
root=Path(__file__).resolve().parents[1]
backup=root/'tmp/publish_optimization_originals'
backup.mkdir(exist_ok=True)
def read(p):
    p=root/p
    dest=backup/p.name
    if not dest.exists():shutil.copy2(p,dest)
    return p,p.read_text(encoding='utf-8')
for domain,cls in [('building','RuntimeEconomyBuildingStore'),('family','RuntimeEconomyFamilyStore'),('trade_escrow','RuntimeEconomyTradeEscrowStore')]:
    p,s=read(f'gdext/src/runtime_economy_{domain}_store.cpp')
    s=s.replace('#include <cstring>','#include <cstring>\n#include "economy_wire_sink.h"')
    old='template <typename T>\nvoid append_pod(std::vector<uint8_t> &out, const T &value) {\n    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);\n    out.insert(out.end(), bytes, bytes + sizeof(T));\n}'
    assert old in s
    s=s.replace(old,'template <typename Sink, typename T>\nvoid append_pod(Sink &out, const T &value) {\n    economy_wire_append(out, value);\n}')
    s,n=re.subn(r'void '+cls+r'::append_wire\(\s*std::vector<uint8_t> &out\) const \{',f'template <typename Sink>\nvoid {cls}::visit_wire(Sink &out) const {{',s)
    assert n==1
    begin=s.index(f'uint64_t {cls}::wire_content_hash()')
    end=s.index('\n}',begin)+2
    s=s[:begin]+f'''void {cls}::append_wire(std::vector<uint8_t> &out) const {{
    visit_wire(out);
}}

uint64_t {cls}::wire_content_hash() const noexcept {{
    EconomyWireHashSink sink{{kFnvOffset}};
    visit_wire(sink);
    return sink.hash;
}}

uint64_t {cls}::mix_wire_hash(uint64_t hash) const noexcept {{
    EconomyWireSizeSink size;
    visit_wire(size);
    EconomyWireHashSink sink{{(hash ^ static_cast<uint64_t>(size.size)) * kFnvPrime}};
    visit_wire(sink);
    return sink.hash;
}}'''+s[end:]
    p.write_text(s,encoding='utf-8')
    p,s=read(f'gdext/src/runtime_economy_{domain}_store.h')
    s=s.replace('    uint64_t wire_content_hash() const noexcept;','    uint64_t wire_content_hash() const noexcept;\n    uint64_t mix_wire_hash(uint64_t hash) const noexcept;\n\nprivate:\n    template <typename Sink> void visit_wire(Sink &out) const;')
    p.write_text(s,encoding='utf-8')
p,s=read('gdext/src/runtime_economy_state.cpp')
for domain in ['building','trade','family']:
    store='trade_escrow' if domain=='trade' else domain
    old=f'''    {{
        std::vector<uint8_t> {domain}_wire;
        {store}.store.append_wire({domain}_wire);
        mix_vector(hash, {domain}_wire);
    }}'''
    assert old in s
    s=s.replace(old,f'    hash = {store}.store.mix_wire_hash(hash);')
p.write_text(s,encoding='utf-8')
p,s=read('gdext/src/economy_graph_stage_dispatch.cpp')
old='''        // commit_epoch 随后可能执行依赖投影的 POD command，先刷新一次。
        if (runtime->formula_owned_bound() && !input.stage_hashes_enabled)
            runtime->flush_formula_owned_domain_mirrors();
'''
assert old in s
s=s.replace(old,'        // ACTIVE 投影在真正执行 POD 命令前或 Host 最终发布时刷新。\n')
p.write_text(s,encoding='utf-8')
p,s=read('gdext/src/runtime_economy_pod.cpp')
old='''    // Promote pending receipts that reached the committed boundary.
    commit_pending_commands();'''
new='''    // ACTIVE 无命令时不构造即将被 Host 再次刷新的投影；有命令仍保留
    // 执行前投影及执行后最终导出，不能让命令读到上一代 domain 数据。
    if (!_commands.empty() && !_input.stage_hashes_enabled &&
        _stage_ops != nullptr && _view.runtime_hook != nullptr) {
        auto *runtime = static_cast<NativeEconomyRuntime *>(_view.runtime_hook);
        if (runtime->formula_owned_bound())
            runtime->flush_formula_owned_domain_mirrors();
    }
    // Promote pending receipts that reached the committed boundary.
    commit_pending_commands();'''
assert old in s
s=s.replace(old,new)
p.write_text(s,encoding='utf-8')
