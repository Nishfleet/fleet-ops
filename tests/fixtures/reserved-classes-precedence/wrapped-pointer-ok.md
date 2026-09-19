# Fixture: wrapped pointer (fleet-ops#5757)
#
# The exact bullet shape the line-based grep false-positived on: the
# surface DOES point at global-standing-rules.md, but the pointer wraps
# onto indented continuation lines below the mentions line. The house wrap
# convention in the live targets is what produces this shape; the
# paragraph-aware gate must ACCEPT it (exit 0, no false positive).

# Some intro paragraph that is not a bullet and mentions nothing relevant.

- Stop only for the canonical reserved classes
  (`nish-vault/_system/shared-memory/global-standing-rules.md` → "Canonical
  reserved-classes list"): money/pricing, privacy, security, legal, brand,
  product direction, customer-data deletion, destructive/irreversible steps,
  and authority Nish has explicitly reserved. This line is a pointer, not a
  restatement (fleet-ops#5641).

- Clients call the app's public API only — never admin cloud/DB/payment/model secrets directly.
