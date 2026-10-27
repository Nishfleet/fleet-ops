import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT = (ROOT / "prompts/orchestrator-handoff.md").read_text()
NEEDS = re.search(r"## Needs Nish\n(.*?)\n## ", TEXT, re.S).group(1)
RESERVED = NEEDS.split("\n\n")[0]
FORBIDDEN = TEXT.split("## Forbidden")[1]


def test_reserved_list_is_the_three_classes():
    low = RESERVED.lower()
    for word in ("money", "security action only nish can take", "no machine can fix"):
        assert word in low
    for dropped in ("privacy", "legal", "brand", "product direction",
                    "destructive or irreversible", "pricing"):
        assert dropped not in low


def test_process_gated_items_still_notify_nish():
    assert "customer-data deletion" in RESERVED.lower()
    assert "production deploys" in RESERVED
    assert "needs-nish-decision" in RESERVED


def test_other_decisions_route_jev_then_one_opus_final_say():
    assert "127.0.0.1:4000/jev" in NEEDS
    assert "p>=0.9" in NEEDS
    assert "claude -p --model claude-opus-5-5" in NEEDS
    assert "never in argv" in NEEDS


def test_forbidden_gates_hold_whatever_jev_or_opus_say():
    for word in ("never rotate or move a secret", "Never deploy",
                 "GitHub Actions secret, variable or environment",
                 "branch protection rule or a token: those need Nish"):
        assert word in FORBIDDEN
    assert "stays forbidden whatever Jev or Opus say" in NEEDS
