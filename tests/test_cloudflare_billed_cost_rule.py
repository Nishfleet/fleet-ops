"""The Cloudflare cost alarm reads the billable-usage API inside its documented contract.

The account-usage API documents two bounds on a read, and the rule needs both:
"the maximum date range is 31 days" on `from`/`to`, and "the provided time range
must include the subscription billing cycle anchor day, otherwise no usage data
is returned" (https://developers.cloudflare.com/api/resources/billing/subresources/usage/).
Two 6ths are at most 31 days apart, so a 31-day window is the narrowest one that
still holds the anchor day and the widest one the endpoint documents.

The rule asked for 35 days, four days past the cap, and on 2026-11-26 its read
failed and the rule reported DatasourceError instead of a cost (fleet-ops#12147).
These tests fail on that window, so a widening cannot put the read past the cap
again without CI saying so.
"""

from pathlib import Path

import yaml

RULE = (
    Path(__file__).resolve().parents[1]
    / "config/grafana/provisioning/alerting/cloudflare-billed-cost.yaml"
)
MAXIMUM_DAYS = 31


def _rule():
    document = yaml.safe_load(RULE.read_text())
    return document["groups"][0]["rules"][0]


def _query(ref_id):
    return next(query for query in _rule()["data"] if query["refId"] == ref_id)


def test_the_read_asks_for_the_documented_maximum_and_no_more():
    """31 days is the documented cap and still holds the anchor day, so the
    window carries both billing periods and the last day of a period is read the
    next day."""
    query = _query("A")
    days = query["relativeTimeRange"]["from"] / 86400
    assert days == MAXIMUM_DAYS, (
        f"the read asks for {days} days; the API documents 31 as the maximum date "
        "range, and a shorter window can miss the billing anchor day and return "
        "no rows at all"
    )
    assert query["relativeTimeRange"]["to"] == 0, "the window must end at the evaluation"
    assert "__timeFrom" in query["model"]["url"] and "__timeTo" in query["model"]["url"], (
        "the request must carry the rule's own window, so the cap above is the cap of the read"
    )


def test_the_read_keeps_one_row_per_service_on_the_latest_published_day():
    """A row per service on the newest day is what makes each service its own
    alert instance; a selector that kept every day would alert on old charges."""
    query = _query("A")
    selector = query["model"]["root_selector"]
    assert "$max(" in selector and "ChargePeriodStart" in selector, (
        "the selector must pick the latest ChargePeriodStart, not the first row"
    )
    assert [column["selector"] for column in query["model"]["columns"]] == [
        "service",
        "day",
        "cost",
    ]
    assert query["model"]["datasource"]["uid"] == "fleet-cloudflare"


def test_the_condition_is_ten_cents_on_one_service_and_stays_loud_when_blind():
    """0.10 USD is the line: steady state is R2 storage at 0.015 a day. A read
    that fails or returns nothing has to be reported, not read as no spend."""
    rule = _rule()
    condition = _query("B")["model"]["conditions"][0]
    assert condition["evaluator"] == {"params": [0.1], "type": "gt"}
    assert condition["query"]["params"] == ["B"]
    assert _query("B")["model"]["expression"] == "A"
    assert rule["condition"] == "B"
    assert rule["noDataState"] == "NoData"
    assert rule["execErrState"] == "Error"
