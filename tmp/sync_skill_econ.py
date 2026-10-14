from pathlib import Path

COPIES = [".cursor", ".codex", ".claude", ".agents", ".codebuddy", ".dsh", "../.cursor"]
REL = "skills/project-keynes-economy-runtime/references/market-algorithms.md"

BIRTH_ANCHOR = "`docs/cpp-dots-runtime/satisfaction-runtime.md`.\n"
BIRTH_TEXT = (
    "\nBirth multiplier: composite/0.70 below the reference, then linear to `carrying_sat_cap_q16`\n"
    "(1.15) at `satisfaction_birth_bonus_reference_q16` (0.85); the part above 1 fades out as load goes\n"
    "from `carrying_soft_start_q16` to 1.0. Base natural death is 7.5%/year, multiplied by the frozen\n"
    "country stat `country.population.death_factor` (technology Modifier, floor 1/3, so 2.5% at full\n"
    "medicine). Use that same `base_death_rate_q32` for replacement fertility and starvation stacking.\n"
)
MOBILITY_ANCHOR = "Do not apply this price-driven path to collectors or services.\n"
MOBILITY_TEXT = (
    "\nThere is no knowledge-sector headcount cap. Upward mobility is gated by\n"
    "`ProfessionProfile.entry_savings_days`: when the target gate exceeds the source gate, the source\n"
    "cohort's per-capita funds must reach `days × _cell_living_cost_per_capita` (nothing is debited).\n"
    "Check it in unemployed-pool eligibility before proportional allocation (rejection code 9,\n"
    "`EMPLOYMENT_REJECTION_ENTRY_SAVINGS`) and while choosing the source ethnicity cohort in all four\n"
    "job-to-job lanes. `_cell_living_cost_per_capita` weights each variant by purchasable coverage\n"
    "(`min(1, 4 × purchasable / (pop × base_qty))`, 1/16 steps) so a thin expensive stock cannot price\n"
    "the whole need.\n"
)

for copy in COPIES:
    path = Path(copy) / REL
    if not path.exists():
        print("missing", path)
        continue
    raw = path.read_bytes()
    eol = "\r\n" if b"\r\n" in raw else "\n"
    text = raw.decode("utf-8").replace("\r\n", "\n")
    if "entry_savings_days" in text:
        print("already", path)
        continue
    ok = True
    for anchor, insert in ((BIRTH_ANCHOR, BIRTH_TEXT), (MOBILITY_ANCHOR, MOBILITY_TEXT)):
        if text.count(anchor) != 1:
            print("anchor not unique/absent", path, repr(anchor[:40]), text.count(anchor))
            ok = False
            continue
        text = text.replace(anchor, anchor + insert)
    path.write_bytes(text.replace("\n", eol).encode("utf-8"))
    print("updated" if ok else "partial", path)
