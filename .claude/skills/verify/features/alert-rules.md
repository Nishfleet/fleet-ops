# Alert rules

Prometheus loads `rootfs/etc/prometheus/fleet_rules.yml`, Alertmanager loads its routes, and every rule test in `config/prometheus-tests/` passes.

## Sub-features

- `rules-check` is `promtool check rules`.
- `rules-test` is `promtool test rules`, one case per rule.
- `routes-check` is `amtool check-config`.

## How to get to it (user POV)

- Change a rule or a route, merge, and the deploy installs it and reloads Prometheus.

## Driving it with docker exec

- **Check.** `docker exec "$RUN" sh -c 'cd /srv/fleet-ops && promtool check rules rootfs/etc/prometheus/*_rules.yml'` prints `SUCCESS` per file.
- **Test.** `docker exec "$RUN" sh -c 'cd /srv/fleet-ops && promtool test rules config/prometheus-tests/*.test.yml'` prints `SUCCESS`.
- **Routes.** `docker exec "$RUN" sh -c 'cd /srv/fleet-ops && amtool check-config rootfs/etc/alertmanager/alertmanager.yml'` prints `SUCCESS`.

## Gotchas

- CI runs the same three checks on pinned box versions. This recipe proves them on the container's packaged versions.
- A new rule must also stay under the owner's cap of 10 (tests/test_owner_caps.py).
