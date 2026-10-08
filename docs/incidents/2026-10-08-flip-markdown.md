# 2026-10-08 Blacksmith flip unit went red though the flip worked

## Impact
`blacksmith-flip.service` failed at 21:03 IST (hourly timer). The flip itself was right: `CI_RUNNER` was set with 0 Blacksmith minutes used. Only the unit's result was wrong, so `systemctl --user list-units --state=failed` showed a failure that was not one. No customer impact.

## Cause
The model ended with `**FLIP: SET**` (bold). The unit's check only accepted the line `FLIP: SET` or `FLIP: DELETE` exactly (`grep -qE "^FLIP: (SET|DELETE)$"`), so the asterisks failed it and the unit exited 1. A model cannot be relied on to never format its output, so a check that rejects emphasis only produces false reds.

## Detection
The VPS thread saw the failed unit and read the journal for that invocation.

## Fix
The check now strips markdown emphasis (`*` and `_`) and the whitespace around each line before matching, and still requires the exact token, whole line (`grep -x`). `FLIP: ERROR`, `FLIP:SET`, `FLIP: SETX`, a prefix such as `xFLIP: SET` and no verdict at all still fail. The prompt's last step now also says to print the verdict in plain text.

Checked against samples with the same pipeline (pass: `**FLIP: SET**`, `__FLIP: DELETE__`, `  FLIP: SET  `, `FLIP: DELETE`; fail: `FLIP: ERROR`, `FLIP:SET`, `FLIP: SETX`, `xFLIP: SET`, no verdict), and the unit's command passes `sh -n` after systemd's `%%` is undone. The ci.yml gate "No shell ${...} or bare %s" finds nothing.

## Prevention
A strict check on model output is only worth its false reds when the strictness catches a real failure. Here the real failures (an error token, no verdict, a wrong token) are still caught. There is no CI test for this unit: adding one means a step in `ci.yml`, which is on the guard list and needs a person. Until then the samples above are the pin.
