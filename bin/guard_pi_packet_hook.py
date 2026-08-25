#!/usr/bin/env python3
"""Claude PostToolUse (Bash) → pi-packet guard.

Historical canonical location: nish-vault/_system/shared-memory/guards/guard_pi_packet.py.
Fleet-ops now owns the canonical implementation in lib/guard_pi_packet.py.
"""
import os, sys
here = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(here, "..", "lib"))
from guard_pi_packet import main  # noqa: E402
sys.exit(main())
