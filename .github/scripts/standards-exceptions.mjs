// standards-exceptions.mjs — parse + validate a repo's `.fleet/standards-exceptions.yml`.
//
// AMENDMENT (Nish, 2026-08-25): rare per-repo exceptions are legitimate but
// must never be the norm. A repo may carry `.fleet/standards-exceptions.yml`
// declaring specific deviations, each with `rule:`, `reason:`, `decided:`
// (date), and `decided_by: nish`. Only Nish-attributed exceptions are honored —
// an agent may PROPOSE one via PR but it merges only with his approval label.
//
// The sync: honors declared exceptions (skips enforcing that rule there),
// REPORTS every active exception in its drift report every run (visible
// forever, never silent), and treats any undeclared deviation as drift to
// repair. Exception count per repo is a tracked number — growth is a smell.
//
// This module is dependency-free and deterministic so it can be unit-tested
// offline against fixtures. It parses a minimal YAML subset by hand (the
// exceptions file is a flat list of objects with string fields) rather than
// pulling a YAML dependency into fleet-ops.

export class ExceptionsFile {
  constructor(text, repo) {
    this.repo = repo;
    this.exceptions = []; // honored (decided_by: nish)
    this.proposed = []; // present but not yet Nish-approved (reported, not honored)
    this.errors = [];
    this._parse(text || "");
  }

  _parse(text) {
    // Minimal flat-YAML parser: a top-level list of `- key: value` maps.
    // Lines like `# comment` or blank are skipped. Indentation marks map
    // continuation. This is deliberately narrow — the file format is fixed.
    const lines = text.split(/\r?\n/);
    let cur = null;
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      const line = raw.replace(/\s+$/, "");
      if (line.trim() === "" || line.trim().startsWith("#")) continue;
      // A list item starts with `- ` at column 0.
      const itemMatch = line.match(/^- (.*)$/);
      if (itemMatch) {
        if (cur) this._push(cur);
        cur = {};
        const rest = itemMatch[1];
        const kv = this._kv(rest);
        if (kv) cur[kv.key] = kv.value;
        else this.errors.push(`line ${i + 1}: expected "key: value" after "- "`);
        continue;
      }
      // Continuation: `  key: value` (indented under the current item).
      const contMatch = line.match(/^\s+ (.*)$/);
      if (contMatch && cur) {
        const kv = this._kv(contMatch[1]);
        if (kv) cur[kv.key] = kv.value;
        else this.errors.push(`line ${i + 1}: expected "key: value"`);
        continue;
      }
      this.errors.push(`line ${i + 1}: unparseable line: ${raw}`);
    }
    if (cur) this._push(cur);
  }

  _kv(s) {
    const m = s.match(/^([a-zA-Z_]+):\s*(.*)$/);
    if (!m) return null;
    return { key: m[1], value: m[2].replace(/^["']|["']$/g, "").trim() };
  }

  _push(obj) {
    const rule = obj.rule;
    if (!rule) {
      this.errors.push(`exception missing required "rule:" field`);
      return;
    }
    const entry = {
      rule,
      reason: obj.reason || "",
      decided: obj.decided || "",
      decided_by: (obj.decided_by || "").trim(),
    };
    if (entry.decided_by === "nish") {
      this.exceptions.push(entry);
    } else {
      // Present but not Nish-approved: report it loudly, do NOT honor it.
      this.proposed.push(entry);
    }
  }

  // True if this repo has a declared, Nish-approved exception for `rule`.
  isExcepted(rule) {
    return this.exceptions.some((e) => e.rule === rule);
  }

  // Summary for the drift report.
  report() {
    return {
      honored: this.exceptions,
      proposed_not_honored: this.proposed,
      errors: this.errors,
      count: this.exceptions.length,
    };
  }
}

// The set of rule names the sync knows how to except. An exception for an
// unknown rule is reported as an error (the rule name must match a real
// standard rule so exceptions cannot silently cover anything).
export const KNOWN_EXCEPTION_RULES = [
  "label-triad",
  "branch-protection",
  "codeowners-gate-paths",
  "merge-group-triggers",
  "thin-caller:secret-scan.yml",
  "thin-caller:semgrep.yml",
  "thin-caller:review-gate.yml",
  "thin-caller:auto-enqueue.yml",
  "allow-auto-merge",
];
