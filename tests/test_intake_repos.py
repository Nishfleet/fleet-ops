"""config/intake-repos.json: the 0509-only admission freeze is lifted."""
import json
import pathlib

CFG = json.loads((pathlib.Path(__file__).parent.parent / "config" / "intake-repos.json").read_text())
ENROLLED = {r["name"]: r for r in CFG["repos"]}
DEFERRED = {r["name"] for r in CFG["deferred"]}
NEW = ("TinyStudio.io-public", "aiconverter-app", "rera-report-card")


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


def test_launch_push_repo_is_admitted_and_swept_first():
    # Nish, 2026-10-15: two-week launch push for Site Rep and SEO Fix Kit.
    entry = ENROLLED["siterep-public"]
    assert entry["product"] is True
    assert set(ENROLLED["0509"]) <= set(entry)
    assert entry["enrolled_by"].startswith("Nish, 2026-10-15")
    assert "siterep-public#173" in entry["enrolled_by"]  # the dated end-of-push review
    # Order only matters to agent.yml's cross-repo sweep loop, which walks .repos[] in order.
    assert CFG["repos"][0]["name"] == "siterep-public"
