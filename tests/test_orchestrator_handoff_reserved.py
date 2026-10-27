"""The hand-off prompt must keep the reserved-class gates and the Jev→Opus routing.

fleet-ops#10440. The reserved list is canonical in the vault
(`global-standing-rules.md` → "Only these reach Nish"); this prompt mirrors it
and must not narrow it, and the deploy/secret gates must stay.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT = (ROOT / "prompts/orchestrator-handoff.md").read_text()
NEEDS = re.search(r"## Needs Nish\n(.*?)\n## ", TEXT, re.S).group(1)
FORBIDDEN = TEXT.split("## Forbidden")[1]


def test_reserved_list_is_mirrored_not_narrowed():
    assert "Only these reach Nish" in NEEDS
    assert "global-standing-rules.md" in NEEDS
    for word in ("privacy", "security", "legal", "brand",
                 "product direction", "customer-data deletion",
                 "destructive or irreversible"):
        assert word in NEEDS.lower()


def test_process_gated_items_are_labelled_so_nish_is_notified():
    assert "process-gated" in NEEDS
    assert "needs-nish-decision" in NEEDS


def test_non_reserved_decisions_route_jev_then_one_opus_final_say():
    assert "127.0.0.1:4000/jev" in NEEDS
    assert "p>=0.9" in NEEDS
    assert "claude -p --model claude-opus-5-5" in NEEDS
    assert "reserved-class item falls through" in NEEDS


def test_forbidden_keeps_actions_and_org_gates():
    for word in ("GitHub Actions secret", "environment", "org-owner key",
                 "branch protection", "ruleset"):
        assert word in FORBIDDEN


def test_fleet_owned_rotation_requires_consumers_and_hides_the_value():
    assert "rotate a secret or token the fleet itself owns" in FORBIDDEN
    assert "every consumer" in FORBIDDEN
    assert "never in argv" in FORBIDDEN
