#!/usr/bin/env python3
"""Claude PreToolUse (Write|Edit|MultiEdit) → shared-file collision guard.

Canonical logic lives in lib/guard_shared_file_collision.py.
"""
import os
import sys

here = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(here, "..", "lib"))
from guard_shared_file_collision import main  # noqa: E402

sys.exit(main())
