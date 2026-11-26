"""The Cloudflare cost alarm reads the billable-usage API inside its documented contract.

The account-usage API documents "the maximum date range is 31 days" on `from`/`to`
(https://developers.cloudflare.com/api/resources/billing/subresources/usage/).
The rule holds the read at that cap so a widening cannot put the read past what
the endpoint documents without CI saying so.

This file asserts only that documented contract. The rest of the rule's
behaviour (the selector, the threshold, the loud-on-blind states) is stock
Grafana alerting, configured and proved on the box by the rule's own evaluation
instances; tests restating those literals would pass however the read behaves.
"""

from pathlib import Path

import yaml

RULE = (
    Path(__file__).resolve().parents[1]
    / "config/grafana/provisioning/alerting/cloudflare-billed-cost.yaml"
)
MAXIMUM_RANGE_DAYS = 31


def _rule():
    document = yaml.safe_load(RULE.read_text())
    return document["groups"][0]["rules"][0]


def _query(ref_id):
    return next(query for query in _rule()["data"] if query["refId"] == ref_id)


def test_the_read_asks_for_no_more_than_the_documented_maximum_range():
    """The API documents 31 days as the maximum date range on `from`/`to`; a
    wider read asks the endpoint for something it does not accept. 31 days is
    also the narrowest window that always holds the billing anchor day (the
    6th), since two 6ths are at most 31 days apart, so the cap and the anchor
    day agree on the same window."""
    query = _query("A")
    assert query["relativeTimeRange"]["from"] <= MAXIMUM_RANGE_DAYS * 86400, (
        "the read asks for more than the API documents as the maximum date range"
    )
    assert query["relativeTimeRange"]["to"] == 0, "the window must end at the evaluation"
    assert "__timeFrom" in query["model"]["url"] and "__timeTo" in query["model"]["url"], (
        "the request must carry the rule's own window, so the cap above is the cap of the read"
    )
