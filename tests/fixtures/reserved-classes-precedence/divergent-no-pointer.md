# Fixture: divergent no-pointer restatement (fleet-ops#5757)
#
# A bullet that enumerates a reserved-classes list WITHOUT pointing at the
# vault source of truth anywhere in the same bullet. This is the true drift
# the #5719 surface-prose gate exists to catch; the paragraph-aware gate
# must still REJECT it (exit 1, fail).

# An intro paragraph that is not a bullet.

- Stop only for the reserved classes: money, pricing, legal, security, and
  destructive steps. Bring everything else autonomously.

- Another unrelated bullet about nothing relevant at all.
