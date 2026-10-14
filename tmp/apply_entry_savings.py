from pathlib import Path
import re

ROOT = Path("Project/project-keynes/data/economy/professions")
TIERS = {
    60: ["artisan", "industrial_worker", "petroleum_worker", "journeyman"],
    180: ["machinist", "electrician", "technician", "scribe", "lorekeeper"],
    365: ["guild_master", "metallurgist", "chemist", "engineer", "manager",
          "scholar", "natural_philosopher"],
    730: ["researcher", "scientist", "industrialist"],
    1095: ["research_scientist", "data_scientist", "ai_researcher"],
}
for days, ids in TIERS.items():
    for pid in ids:
        path = ROOT / f"{pid}.tres"
        data = path.read_bytes()
        eol = b"\r\n" if b"\r\n" in data else b"\n"
        text = data.decode("utf-8")
        assert "entry_savings_days" not in text, pid
        text = text.rstrip("\r\n") + eol.decode() + f"entry_savings_days = {days}" + eol.decode()
        path.write_bytes(text.encode("utf-8"))
        print(pid, days, eol)
