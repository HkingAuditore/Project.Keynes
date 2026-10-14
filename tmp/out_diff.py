import re, sys

def load(path, tag):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith(tag):
            m = re.search(r"day=(\d+)", line)
            out.setdefault(int(m.group(1)), line.split()[2:])
    return out

tag = "[climate-out]"
base = load(sys.argv[1], tag)
for other_path in sys.argv[2:]:
    other = load(other_path, tag)
    first = None
    for d in sorted(set(base) & set(other)):
        if base[d] != other[d]:
            first = d
            break
    print("==", other_path, "first climate-out diff:", first)
    if first is not None:
        for p, q in zip(base[first], other[first]):
            mark = "" if p == q else "   <== DIFF"
            print("  A", p, mark)
            if p != q:
                print("  B", q)
