import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PANELS = json.loads((ROOT / "config/grafana/dashboards/fleet.json").read_text())["panels"]
PRODUCTS = {"0509", "aiconverter-app", "rera-report-card", "siterep-public", "tether", "TinyStudio.io-public"}


def test_product_prs_per_repo_leads_the_dashboard():
    first = min(PANELS, key=lambda p: (p["gridPos"]["y"], p["gridPos"]["x"]))
    assert first["type"] == "row" and "Product" in first["title"]
    table = next(p for p in PANELS if p["title"].startswith("Merged per repo"))
    assert table["gridPos"]["y"] == 1 and table["timeFrom"] == "7d"
    target = table["targets"][0]
    assert target["datasource"]["type"] == "grafana-github-datasource"
    assert target["queryType"] == "Pull_Requests"
    assert target["options"]["timeField"] == 2
    query = target["options"]["query"]
    assert query.startswith("is:merged ")
    assert {t.split("/")[1] for t in query.split() if t.startswith("repo:")} == PRODUCTS


def test_every_other_panel_sits_below_the_lead_block():
    others = [p for p in PANELS if p["id"] not in (74, 75)]
    assert all(p["gridPos"]["y"] >= 7 for p in others)
    assert len({p["id"] for p in PANELS}) == len(PANELS)
