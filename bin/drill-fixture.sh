#!/bin/sh
# auto-revert drill fixture (will be auto-reverted)
# Harmless: pure addition, not in MANIFEST, ships nothing to users.
# Triggers a shellcheck parse error (SC1072/SC1073) to turn CI red.
echo "drill fixture
