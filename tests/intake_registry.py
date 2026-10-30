"""config/intake-repos.json, read one way by every test that needs a repo list.

The dispatcher admits a repo with `.repos[] | .name == $n and .product == true`
(.github/workflows/agent-dispatch.yml), so a product is an enrolled repo whose
product flag is the JSON boolean true. A repo the registry names in no section
was deleted, and later-sweep mints one App token per enrolled name (fleet-ops#11087).
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config/intake-repos.json"


def registry():
    return json.loads(CONFIG.read_text())


def _repo_sections():
    """The registry sections that list repos, by the shape their entries share."""
    sections = {}
    for name, section in registry().items():
        if not isinstance(section, list):
            continue
        entries = [entry for entry in section if isinstance(entry, dict) and "name" in entry]
        if entries:
            sections[name] = entries
    return sections


def repo_names():
    """Every repo the registry names, in any section that lists repos."""
    return {entry["name"] for entries in _repo_sections().values() for entry in entries}


def enrolled_repos():
    """The repos the dispatcher admits work for."""
    sections = _repo_sections()
    assert "repos" in sections, "the registry has no repos section, and the dispatcher reads .repos[]"
    return sections["repos"]


def product_names():
    """Every enrolled repo the dispatcher admits as a product.

    A repo whose product flag is missing or is not the JSON boolean true would
    drop out of the set silently, so the flag is checked on every enrolled repo.
    """
    names = set()
    for entry in enrolled_repos():
        assert isinstance(entry.get("product"), bool), f"{entry['name']} must declare product as a JSON boolean"
        if entry["product"]:
            names.add(entry["name"])
    return names
