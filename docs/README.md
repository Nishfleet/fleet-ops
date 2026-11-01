# How the fleet runs

Short on purpose. The files named here are the record; when this page and a
live file disagree, the live file wins. Postmortems stay in `docs/incidents/`.

## What runs on the box

- One VPS, one `nish` user. Every long-running piece is a systemd unit whose
  file lives in `systemd/` or `rootfs/etc/systemd/system/`. Each unit's own
  `Description=` says what it does: `systemctl list-units 'fleet-*'`.
- Host setup is Ansible: `ansible/host.yml` (config) and `ansible/update.yml`
  (weekly update).
- Models go through the LiteLLM router on `127.0.0.1:4000`. Its seats live in
  `config/litellm-proxy.yaml`. Health: `/health/readiness` and
  `litellm_deployment_state` on `/metrics`.
- Workers run as GitHub Actions jobs on the box's self-hosted runners
  (`.github/workflows/`).

## How a change lands

1. An issue says what to change.
2. A branch and a pull request make the change.
3. GitHub's own gate merges it: the required `ci` and `Gitleaks` checks, then
   the merge queue (`gh pr merge --auto`).
4. A push to `main` is the deploy: the box fetches `main` and applies it.

Nothing changes the box by hand. A hand fix is lost on the next deploy.

## Where alerts go

- Grafana alert rules live in `config/grafana/provisioning/alerting/`.
- Each firing alert opens a fleet-ops issue, so a worker can fix it.
- Each rule carries a `severity` label. Only `critical` rules page the owner.
  The target (fleet-ops#10935): under 10 rules, each a user-felt symptom.

The box applies main only when its top commit is GitHub-signed (ansible-pull --verify-commit); merges through the queue are signed, direct pushes are not.
