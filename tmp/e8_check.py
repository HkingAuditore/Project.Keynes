from pathlib import Path
h = Path("gdext/src/native_simulation_host.h").read_text(encoding="utf-8")
i = h.find("static constexpr uint32_t implemented_domain_mask")
print(h[i : i + 900])
text = Path("gdext/src/native_simulation_host.cpp").read_text(encoding="utf-8")
i = text.find("stage.domain == RuntimeDomainId::MODIFIER &&")
chunk = text[i : i + 2800]
for line in chunk.splitlines():
    if "effect_reason" in line or "\\0" in line or "'\\0'" in line:
        print(repr(line))
