from pathlib import Path
root = Path("Project/project-keynes/data/economy/buildings")
hunting = (root / "stone_age_hunting_camp.tres").read_text(encoding="utf-8")
cable = (root / "insulated_cable_plant.tres").read_text(encoding="utf-8")
print("hunting_has_tools", 'input_good_ids = PackedStringArray("tools")' in hunting)
print("hunting_output", "6670" in hunting)
print("cable_required", "32768, 65536, 32768" in cable or "65536, 65536, 32768, 65536, 32768" in cable)
print("cable_candidates", 'PackedStringArray("plastics", "synthetic_rubber")' in cable)
