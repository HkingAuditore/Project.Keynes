"""Look up polytech-tree reference entries (year, era, prereqs) by Chinese or English name.

Usage: python polytech_lookup.py 名称1 名称2 ...
Reads tmp/polytech/techs.json (downloaded from secwind7/polytech-tree, data CC BY 4.0).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parents[2] / "tmp" / "polytech" / "techs.json"


def load():
    techs = json.loads(DATA.read_text(encoding="utf-8"))
    return techs, {t["id"]: t for t in techs}


def find(techs, query: str):
    q = query.lower()
    exact, partial = [], []
    for tech in techs:
        names = [tech.get("name", ""), tech.get("nameEn", "")] + list(tech.get("aliases", []))
        lowered = [n.lower() for n in names if n]
        if q in lowered:
            exact.append(tech)
        elif any(q in n for n in lowered):
            partial.append(tech)
    return exact or partial[:4]


def main() -> None:
    techs, by_id = load()
    for query in sys.argv[1:]:
        for tech in find(techs, query):
            prereqs = ",".join(by_id[p]["name"] if p in by_id else p for p in tech.get("prereqs", []))
            related = ",".join(by_id[p]["name"] if p in by_id else p for p in tech.get("related", [])[:5])
            print("%s | %s(%s) %s %s imp=%s | pre=[%s] | rel=[%s]" % (
                query, tech["name"], tech.get("nameEn", ""), tech.get("year"), tech.get("era"),
                tech.get("importance"), prereqs, related))


if __name__ == "__main__":
    main()
