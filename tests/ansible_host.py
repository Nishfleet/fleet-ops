"""ansible/host.yml with each `import_tasks` file put back in its place.

The play's tasks live in ansible/tasks/*.yml (one file per concern, fleet-ops#10720).
Tests read the play as one text, the same text host.yml held before the split.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = ROOT / "ansible/host.yml"


def text() -> str:
    def inline(m: re.Match) -> str:
        body = (ROOT / "ansible" / m.group(1)).read_text()
        return "".join("    " + line if line.strip() else line for line in body.splitlines(True))

    return re.sub(r"^    - ansible\.builtin\.import_tasks: (\S+)\n", inline, HOST.read_text(), flags=re.M)


def play() -> dict:
    import yaml  # only the tests that read the play as data need PyYAML

    return yaml.safe_load(text())[0]
