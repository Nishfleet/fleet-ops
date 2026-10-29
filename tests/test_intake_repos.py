"""config/intake-repos.json: the 0509-only admission freeze is lifted."""
import json
import pathlib

CFG = json.loads((pathlib.Path(__file__).parent.parent / "config" / "intake-repos.json").read_text())
ENROLLED = {r["name"]: r for r in CFG["repos"]}
DEFERRED = {r["name"]: r for r in CFG["deferred"]}
NEW = ("TinyStudio.io-public", "aiconverter-app", "rera-report-card", "tether")
UNHOOKED = ("mailbox", "claude-mods", "fleet-console-worker", "pi-runner-guard")
CONTROL_PLANE = ("claude-mods", "fleet-console-worker", "pi-runner-guard")
STUB_PENDING = ("nish-vault", "owner-gate")


def test_the_one_unhooked_repo_whose_code_is_a_product_is_enrolled():
    # mailbox is the only one of the four whose code a customer uses; the other three gate the fleet itself.
    entry = ENROLLED["mailbox"]
    assert entry["product"] is True
    assert set(ENROLLED["0509"]) <= set(entry)
    assert "2026-10-28" in entry["enrolled_by"]


def test_repos_that_gate_the_fleet_itself_are_never_enrolled():
    # A repo in .repos is editable by a worker. model-lanes decides every agent's models and subagents,
    # fleet-console-worker holds the board token and the enrolled signing keys, and pi-runner-guard decides
    # what a worker's own tools may do, so each of them can loosen the fleet's own gate (fleet-ops#10653).
    for name in CONTROL_PLANE:
        assert name not in ENROLLED, name
        entry = DEFERRED[name]
        assert entry["product"] is not True, name
        assert "2026-10-28" in entry["deferred_by"], name
        assert "control plane" in entry["reason"].lower(), name
        assert "Re-enrol via PR" in entry["reason"], name


def test_every_unhooked_repo_is_either_enrolled_or_deferred_never_both():
    for name in UNHOOKED:
        assert (name in ENROLLED) ^ (name in DEFERRED), name


def test_repos_whose_stub_is_not_on_main_stay_deferred():
    for name in STUB_PENDING:
        assert name in DEFERRED, name
        assert name not in ENROLLED, name


def test_new_product_repos_are_admitted():
    for name in NEW:
        assert ENROLLED[name]["product"] is True, name  # agent-dispatch admit needs .product == true


def test_new_entries_copy_the_0509_shape():
    for name in NEW:
        assert set(ENROLLED["0509"]) <= set(ENROLLED[name]), name


def test_enrolled_repos_are_not_deferred_or_excluded():
    excluded = {r["name"] for r in CFG["excluded"]}
    for name in ENROLLED:
        assert name not in DEFERRED and name not in excluded, name


def test_archived_tinystudio_in_is_not_admitted():
    # tinystudio-in was archived 2026-10-12; TinyStudio continues in TinyStudio.io-public.
    assert "tinystudio-in" not in ENROLLED


def test_zero_five_nine_exclusive_deferrals_are_gone():
    assert "siterep-public" not in DEFERRED
    for r in CFG["deferred"]:
        assert "0509-exclusive" not in r.get("reason", "").lower(), r["name"]


def test_launch_push_repos_are_enrolled_like_0509_with_a_dated_end_review():
    # Nish, 2026-10-15: two-week launch push for Site Rep and SEO Fix Kit.
    for name in ("siterep-public", "seo-fix-kit"):
        entry = ENROLLED[name]
        assert entry["product"] is True, name
        assert set(ENROLLED["0509"]) <= set(entry), name
        assert "siterep-public#173" in entry["enrolled_by"], name


def test_sweep_only_repos_get_the_top_up_sweep_but_no_intake():
    sweep_only = {r["name"] for r in CFG["sweep_only"]}
    assert sweep_only == {"fleet-ops", "drive"}
    assert not sweep_only & set(ENROLLED)
    assert "fleet-ops" in DEFERRED and "drive" not in DEFERRED
    agent = (pathlib.Path(__file__).parent.parent / ".github" / "workflows" / "agent.yml").read_text()
    assert ".sweep_only[]?.name" in agent
