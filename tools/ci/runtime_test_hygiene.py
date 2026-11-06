"""Keep native file traces and newly created test artifacts out of the checkout."""
from pathlib import Path
import subprocess
FILE_SWITCHES = ("PK_SIM_DAY_TRACE", "PK_GOLDEN_COUNTRY_TRACE", "PK_ECONOMY_COST_CSV", "PK_RUNTIME_WATERFALL_CSV")
SOURCE_SUFFIXES = {".cpp", ".h", ".py", ".gd", ".uid", ".md", ".json"}
def trace_environment(environment, logs, name):
    result = dict(environment)
    for key in FILE_SWITCHES:
        if result.get(key): result[key] = str((logs / (name + "-" + key + ".log")).resolve())
    return result

def untracked(root):
    data = subprocess.check_output(["/usr/bin/git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root)
    return set(data.decode().rstrip("\0").split("\0")) - {""}

def unexpected_artifacts(before, after):
    return sorted(path for path in after - before if Path(path).suffix not in SOURCE_SUFFIXES)
