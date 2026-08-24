siterep.net failed its uptime probe. Diagnose and act. Never page or message Nish. Never print secrets.

Evidence:
- journalctl --user -u siterep-uptime.service -n 50
- The probe is a single curl -fsS -m 15 of https://siterep.net asserting HTTP 200 + the <title> marker.

Diagnose:
1. Is it deploy-correlated? Compare the live release SHA endpoint (https://siterep.net/api/public/release-status) against recent siterep-deploy journal (journalctl --user -u siterep-deploy -u siterep-deploy-verify -u siterep-deploy-rollback -n 100).
2. If a deploy in the last hour matches the breakage AND siterep-deploy-rollback.service exists and is idle (not already failed/running), start it: systemctl --user start siterep-deploy-rollback.service. Then verify recovery by running /home/nish/.local/bin/siterep-uptime directly and showing it green.
3. If NOT deploy-correlated, diagnose what is fixable from this box:
   - DNS resolution for siterep.net
   - Local connectivity (curl the endpoint yourself)
   - CF-side outage (Cloudflare status page) = nothing fixable from here
4. If unfixable from here, file a gh issue in Nishfleet/siterep titled "UPTIME: siterep.net failing probes since <UTC ts>" with the evidence (journal tail, no secrets), then exit nonzero.

Constraints:
- Never page, email, or message Nish.
- Never print secrets or credential values.
- A rollback is the only live-site action you may take, and only when deploy-correlated.
- Exit nonzero if the site is still failing when you finish.
