"""ansible/host.yml with each `import_tasks` file put back in its place.

The play's tasks live in ansible/tasks/*.yml (one file per concern, fleet-ops#10720).
Tests read the play as one text, the same text host.yml held before the split. `text(rev)`
reads the play at a commit the same way, so a test can diff the play against main's copy at
the rev it holds.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = ROOT / "ansible/host.yml"


def text(rev: str = "", play_file: str = "ansible/host.yml") -> str:
    def show(path: str) -> str:
        if not rev:
            return (ROOT / path).read_text()
        return subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout

    def inline(m: re.Match) -> str:
        body = show(f"ansible/{m.group(1)}")
        return "".join("    " + line if line.strip() else line for line in body.splitlines(True))

    return re.sub(r"^    - ansible\.builtin\.import_tasks: (\S+)\n", inline, show(play_file), flags=re.M)


def play(rev: str = "", play_file: str = "ansible/host.yml") -> dict:
    import yaml  # only the tests that read the play as data need PyYAML

    return yaml.safe_load(text(rev, play_file))[0]
