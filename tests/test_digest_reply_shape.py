"""The digest reply shape gate (Nishfleet/fleet-ops#9706).

The evening digest of 2026-10-11 (execution a8721a52) shipped Nish a reply
with ten bold sections, internal tool names, config advice and an approval
ask, breaking the prompt's own rule: at most 6 short plain lines, no
questions. The fix lives in the canonical prompts under config/hermes/
(applied to the live jobs with the stock `hermes cron edit`), and this file
holds the machine side:

- the canonical prompts must carry the fixed reply contract,
- the shape checker must flag all five fixtures shaped like the shipped replies
  from before the fix (labels written by a non-Claude model before the rewrite, in
  tests/evals/cases/digest_reply_shape.json - the builder graded none),
- the first shipped reply after the fix (digest-evening execution 634b61c6,
  2026-10-13T09:46 IST, delivered to Telegram) must pass clean,
- ci.yml must run this file, so a rewired CI cannot drop the gate silently.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROMPTS = [ROOT / "config/hermes/digest-morning.md", ROOT / "config/hermes/digest-evening.md"]
CASES = ROOT / "tests/evals/cases/digest_reply_shape.json"
CI = ROOT / ".github/workflows/ci.yml"

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
    "reserved class", "workflow", "worker", "seat", "lane",
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
]
_PERSON_RES = re.compile(r"\bI\b|\b(I'll|I've|I'm|me|my|myself)\b", re.IGNORECASE)
_BULLET_RES = re.compile(r"^\s*[-*•]\s")
_HEADER_RES = re.compile(r"^\s*#{1,6}\s")
_SECTION_RES = re.compile(r"^[^a-zA-Z0-9]*\b[A-Z][^:]{2,60}:\s*$")
_URL_RES = re.compile(r"https?://\S+")


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
        if _SECTION_RES.match(_URL_RES.sub(" ", ln)):
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
    if _PERSON_RES.search(text):
        violations.append("first-person")
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
        "no cause, no tool or setting name, no suggestion",
        "never its cause, never a tool, setting, profile or permission name",
        "Quiet 12 hours",
        "Only the short reply described in the last step (REPLY) is the product",
    ]


def test_canonical_prompts_carry_the_reply_contract():
    for prompt in PROMPTS:
        text = prompt.read_text()
        missing = [s for s in _required_contract() if s not in text]
        assert not missing, f"{prompt.name} is missing the fixed contract: {missing}"


def test_labelled_replies_flag():
    """Every fixture shaped like a shipped reply the outside labeler called a violation must flag here."""
    data = json.loads(CASES.read_text())
    assert data["labeller"]["calls"] == 1
    assert {c["id"] for c in data["cases"]} == {"m11", "e11", "m12", "e12", "m13"}, (
        "a labelled case went missing: the gate weakens silently"
    )
    for case in data["cases"]:
        got = check_reply_shape(case["reply"])
        if case["label"] == "violation":
            assert got, f"{case['id']} ({case['source']}) is labelled a violation but the checker passed it"
        else:
            assert not got, f"{case['id']} obeys but the checker flagged {got}"


def test_post_fix_reply_passes():
    assert check_reply_shape(POST_FIX_REPLY) == []


def test_quiet_template_passes():
    assert check_reply_shape(_QUIET_LINE) == []


def test_issue_number_in_text_flags():
    assert "internal-names" in check_reply_shape("Fixed: the rotation (#9433)")


def test_ci_runs_this_file():
    assert "tests/test_digest_reply_shape.py" in CI.read_text()
