"""The digest reply shape gate (Nishfleet/fleet-ops#9706).

The evening digest of 2026-10-11 (execution a8721a52) shipped Nish a reply
with ten bold sections, internal tool names, config advice and an approval
ask, breaking the prompt's own rule: at most 6 short plain lines, no
questions. The fix lives in the canonical prompts under config/hermes/
(applied to the live jobs with the stock `hermes cron edit`), and this file
holds the machine side:

- the canonical prompts must carry the fixed reply contract,
- a reply that is a sentence about the tools instead of the digest (the 08:00
  IST morning run of 2026-10-11, execution prefix e078ee1c, shipped a single
  sentence about which tools to use) flags under a named tooling-meta class,
- the shape checker must flag all five fitted fixtures shaped like the shipped replies
  from before the fix plus the judge seat's six held-out samples (labels written
  by non-Claude model families before the class was fitted to the fitted set,
  in tests/evals/cases/digest_reply_shape.json: the first labeller labelled the
  fitted fixtures, the second wrote and labelled the held-out group - the
  builder graded none),
- the first shipped reply after the fix (digest-evening execution 634b61c6,
  2026-10-13T09:46 IST, delivered to Telegram) must pass clean,
- the reply shapes that shipped on 2026-10-19 (execution 682de9846caa run
  "All facts gathered" plus bold sections and duplicated lines) and on
  2026-10-20 (execution 59de77f7: "are both live", "nothing new to wait on")
  must flag, so the classes that came back after the first fix cannot return.

Fleet-ops#9925 adds the second question, with its own labels (labeller_9925, a
non-Claude model, both calls before the prompt edit): no routine background-job
success filed as news. The checker flags routine-success-as-news, the fitted n*
fixtures and the judge-written held-out h* cases pin it, and the evening prompt
demotes the daily-edition line to a routine confirmation.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROMPTS = [ROOT / "config/hermes/digest-morning.md", ROOT / "config/hermes/digest-evening.md"]
CASES = ROOT / "tests/evals/cases/digest_reply_shape.json"

POST_FIX_REPLY = """Merged count could not be read
Production deploy failed https://example.com/alpha/actions/runs/1
Production deploy failed https://example.com/beta/actions/runs/2
and 2 more broken
product capacity reservation https://example.com/alpha/issues/3
security cleanup https://example.com/alpha/issues/4"""

_QUIET_LINE = "Quiet 12 hours, 0 merged."

_FORBIDDEN_NAMES = [
    "jev", "clef", "tincan", "hermes", "tirith", "litellm", "grafana",
    "prometheus", "agent-dispatch", "agent dispatch", "opus-vet",
    "e2e-scheduled", "lighthouse", "opencode",
    "cursor", "devin", "claude", "cron", "cron_mode", "reserved-class",
    "reserved class", "workflow", "worker", "seat", "lane", "cloudflare",
    "0509", "fleet-ops", "aiconverter", "tinystudio", "siterep",
    "inish-site", "nishfleet", "nish3451",
]
_FORBIDDEN_RES = [
    re.compile(r"\bD1\b"),
    re.compile(r"\bJ\d\b"),
    re.compile(r"[A-Z0-9]+_(TOKEN|KEY|SECRET)\b"),
    re.compile(r"\bkey\s+\d+\b", re.IGNORECASE),
    re.compile(r"(?<!\w)#\d+\b"),
]
_ASK_RES = [
    re.compile(r"\?"),
    re.compile(r"\b(do you want|please|should we|let me know|next step|next action|"
               r"unless you direct|your call|escalate|approv\w+|renew\w*|bench|"
               r"propose\w*|recommend\w*|suggest\w*|consider|ping me)\b", re.IGNORECASE),
]
_CONFIG_RES = [
    re.compile(r"\b(config|configs|setting|settings|profile|permission|permissions|"
               r"secret|secrets|token|tokens|env var|environment variable|"
               r"deny rule|webhook)\b", re.IGNORECASE),
]
_COMMAND_RES = [
    re.compile(r"[`]"),
    re.compile(r"\$\("),
    re.compile(r"/home/|/dev/|/usr/"),
    re.compile(r"\.(md|json|ya?ml|sh|py)\b", re.IGNORECASE),
    re.compile(r"\b(curl|systemctl|sudo|bash|gh)\b", re.IGNORECASE),
]
_NOISE_RES = [
    re.compile(r":\s*\d{3}\b"),
    re.compile(r"\bno new\b", re.IGNORECASE),
    re.compile(r"\b(active|all[ -]green|healthy|nothing (is )?broken)\b", re.IGNORECASE),
    re.compile(r"\bnothing (new|to wait|changed)\b", re.IGNORECASE),
    re.compile(r"\bboth live\b|\b(are|is|were|was)\s+live\b", re.IGNORECASE),
    re.compile(r"\bup and running\b|\brunning normally\b|\b(are|is)\s+up\b|\bback online\b", re.IGNORECASE),
]
_NARRATION_RES = [
    re.compile(r"\ball facts gathered\b", re.IGNORECASE),
    re.compile(r"\bnow i have\b", re.IGNORECASE),
    re.compile(r"\bi have everything\b", re.IGNORECASE),
    re.compile(r"\bhere (is|are) the (reply|digest|summary)\b", re.IGNORECASE),
]
_TOOLING_META_RES = [
    re.compile(r"\btools?\b", re.IGNORECASE),
    re.compile(r"\bbuilt-ins?\b", re.IGNORECASE),
    re.compile(r"\btoolset\b", re.IGNORECASE),
    re.compile(r"\bcapabilit(?:ies|y)\b", re.IGNORECASE),
    re.compile(r"\bweb[- ]?(?:fetch|browser|extract)\b", re.IGNORECASE),
    re.compile(r"\bcached cop(?:y|ies)\b", re.IGNORECASE),
]
_PERSON_RES = re.compile(r"\bI\b|\b(I'll|I've|I'm|me|my|myself)\b", re.IGNORECASE)
_BULLET_RES = re.compile(r"^\s*[-*•]\s")
_HEADER_RES = re.compile(r"^\s*#{1,6}\s")
_SECTION_RES = re.compile(r"^[^a-zA-Z0-9]*\b[A-Z][^:]{2,60}:\s*$")
_URL_RES = re.compile(r"https?://\S+")
_NEWS_RES = [
    re.compile(r"\b(published|shipped|released|launched)\b[^.!?\n]*\b(edition|publish)\b", re.IGNORECASE),
    re.compile(r"\b(edition|publish)\b[^.!?\n]*\b(published|shipped|released|launched)\b", re.IGNORECASE),
    re.compile(r"\b(brand|fresh|shiny)[ -]new\b", re.IGNORECASE),
    re.compile(r"\bnew edition\b", re.IGNORECASE),
]


def news_rule_hits(reply: str) -> list[str]:
    """Patterns a reply hits that present a scheduled job's routine success as news (#9925)."""
    text = _URL_RES.sub(" ", reply)
    return [r.pattern for r in _NEWS_RES if r.search(text)]


def check_reply_shape(reply: str) -> list[str]:
    """Return the shape-rule violations in a digest reply, empty when it obeys."""
    if not reply.strip():
        return ["empty"]
    violations: list[str] = []
    lines = [ln for ln in reply.splitlines() if ln.strip()]
    if len(lines) > 6:
        violations.append("lines")
    text = _URL_RES.sub(" ", reply)
    for ln in lines:
        if _BULLET_RES.match(ln) or _HEADER_RES.match(ln) or "**" in ln:
            violations.append("sections")
    for ln in lines:
        if _SECTION_RES.match(ln):
            violations.append("sections")
    lowered = text.lower()
    if any(re.search(r"(?<![a-z0-9])" + re.escape(name) + r"(?:s|es)?(?![a-z0-9])", lowered) for name in _FORBIDDEN_NAMES) or any(r.search(text) for r in _FORBIDDEN_RES):
        violations.append("internal-names")
    if any(r.search(text) for r in _ASK_RES):
        violations.append("question-or-ask")
    if any(r.search(text) for r in _CONFIG_RES):
        violations.append("config-advice")
    if any(r.search(text) for r in _COMMAND_RES):
        violations.append("commands-or-paths")
    if any(r.search(text) for r in _NOISE_RES):
        violations.append("all-green-noise")
    if any(r.search(text) for r in _NARRATION_RES):
        violations.append("narration")
    if _PERSON_RES.search(text):
        violations.append("first-person")
    if news_rule_hits(reply):
        violations.append("routine-success-as-news")
    if any(r.search(text) for r in _TOOLING_META_RES):
        violations.append("tooling-meta")
    return sorted(set(violations))


def _required_contract():
    """Sentences the fixed reply contract is made of; every canonical prompt carries them."""
    return [
        "at most 6 short lines",
        "no headings, no bold text, no bullet lists",
        "A service that runs normally takes no line",
        '"and N more broken"',
        '"and N more waiting"',
        "never speak as",
        "Never ask Nish a question, never propose or recommend a change or fix",
        "could not be read",
        "If the terminal tool itself will not run",
        "A sentence about the tools used to collect the facts is never part of the reply",
        "no cause, no tool or setting name, no suggestion",
        "never its cause, never a tool, setting, profile or permission name",
        "Quiet 12 hours",
        "Only the short reply described in the last step (REPLY) is the product",
        "The reply is your whole final response",
        "a line whose only point is that a check passed or a service is live, active, up or running",
        "vendor or cloud provider names",
        'never write "nothing new", "nothing to wait on"',
        "Before you send, re-read your draft",
        "not even as a sentence that it is live, up or running",
        "A scheduled job's own success is a routine confirmation, never one of the changes that matter",
        "is never described as a change, even though the TOTAL counts it",
        "A scheduled job's routine success is a routine confirmation, never news",
        "it never reads as a ship",
    ]


def test_canonical_prompts_carry_the_reply_contract():
    for prompt in PROMPTS:
        text = prompt.read_text()
        missing = [s for s in _required_contract() if s not in text]
        assert not missing, f"{prompt.name} is missing the fixed contract: {missing}"


FITTED_IDS = {"m11", "e11", "m12", "e12", "m13", "n1", "n2", "n3", "n4", "n5"}
HELDOUT_IDS = {"r1", "r2", "r3", "r4"}
TOOLING_IDS = {"e20", "e19", "h1", "h2", "h3", "h4", "h5", "h6"}


def test_labelled_replies_flag():
    """Every fitted fixture the outside labelers called a violation must flag; fitted cleans must pass.

    The held-out r* cases (written and labelled by the non-Claude labeller) pin the
    #9925 news rule alone: a violation must trip news_rule_hits, a clean reply must
    not trip it. Their unrelated shape defects stay with the shape rules, which the
    fitted fixtures already gate.
    """
    data = json.loads(CASES.read_text())
    assert data["labeller"]["calls"] == 1
    assert data["labeller_9925"]["calls"] == 2
    assert data["labeller_repeat"]["calls"] == 1
    assert data["heldout_labeller"]["calls"] == 1
    assert {c["id"] for c in data["cases"]} == FITTED_IDS | HELDOUT_IDS | TOOLING_IDS, (
        "a labelled case went missing: the gate weakens silently"
    )
    for case in data["cases"]:
        if case["id"] in HELDOUT_IDS:
            hits = news_rule_hits(case["reply"])
            if case["label"] == "violation":
                assert hits, f"{case['id']} is labelled a routine-success-as-news violation but the news rule passed it"
            else:
                assert not hits, f"{case['id']} obeys the news rule but it hits {hits}"
            continue
        got = check_reply_shape(case["reply"])
        if case["label"] == "violation":
            assert got, f"{case['id']} ({case['source']}) is labelled a violation but the checker passed it"
        else:
            assert not got, f"{case['id']} obeys but the checker flagged {got}"


def test_evening_budget_keeps_the_unknown_daily_page_line():
    """The UNKNOWN daily-page line is the only site-down signal: it sits with the broken lines, never in the cut tail."""
    text = (PROMPTS[0].parent / "digest-evening.md").read_text()
    assert "a step-5 UNKNOWN daily-page line is one of these two, never cut" in text


def test_post_fix_reply_passes():
    assert check_reply_shape(POST_FIX_REPLY) == []


def test_quiet_template_passes():
    assert check_reply_shape(_QUIET_LINE) == []


def test_green_status_and_no_news_lines_flag():
    for reply in [
        "3 merged: the nightly publish, a token fix, and a CI check. Gateway and tincan relay are both live.",
        "The nightly publish went out and the secret scan is up.",
        "51 watched items unchanged; nothing new to wait on.",
        "Nothing changed and nothing is broken.",
        "All facts gathered. Now I have everything for the reply.\n3 merged.",
    ]:
        got = check_reply_shape(reply)
        assert "all-green-noise" in got or "narration" in got or "internal-names" in got, (reply, got)


def test_plain_status_lines_pass():
    for reply in [
        "Nothing merged in the last 12 hours.",
        "3 merged: the nightly publish, a sign-in fix, and a CI check.",
        "And 2 more waiting; 47 items unchanged.",
    ]:
        assert check_reply_shape(reply) == [], reply


def test_tool_chatter_reply_flags_tooling_meta():
    """The 2026-10-11 morning failure (execution e078ee1c) is a tooling sentence with no digest content."""
    shipped = "I need to use the caller's tools rather than my own built-ins."
    got = check_reply_shape(shipped)
    assert "tooling-meta" in got, f"the tool-chatter class escaped the gate: {got}"
    assert "first-person" in got
    assert check_reply_shape("The caller's tools must run instead of the agent's built-ins.") == [
        "tooling-meta"
    ]


def test_issue_number_in_text_flags():
    assert "internal-names" in check_reply_shape("Fixed: the rotation (#9433)")


def test_routine_edition_line_shape():
    assert check_reply_shape("Daily edition: out (2026-10-20)") == []
    assert "routine-success-as-news" in check_reply_shape(
        "The daily page published a brand-new edition (2026-10-20) today."
    )
    assert news_rule_hits("Daily edition published successfully")
    assert not news_rule_hits("The nightly publish could not run last night.")


def test_evening_edition_line_is_a_routine_confirmation():
    text = PROMPTS[1].read_text()
    for sentence in [
        "a new edition ships every day",
        "the changed date alone is a routine confirmation, never news",
        "routine daily-edition line in the words step 5 gives",
    ]:
        assert sentence in text
    assert "only when it has news" not in text, "the daily-edition line is no longer a news slot"


def test_morning_files_no_edition_line():
    text = PROMPTS[0].read_text()
    assert "site line" not in text
    assert "A scheduled job's own success is a routine confirmation, never one of the changes that matter" in text
