import subprocess
from pathlib import Path
files = subprocess.run(["git", "diff", "--name-only", "--", "Project/project-keynes/data"], capture_output=True, text=True).stdout.split()
for f in files:
    p = Path(f)
    data = p.read_bytes()
    if b"\r\n" in data:
        p.write_bytes(data.replace(b"\r\n", b"\n"))
        print("fixed", f)
