# 2026-10-08: the Photon iMessage stream never went live, and the watchdog that should restart it is blind

Blameless. Times are IST unless a value is quoted in UTC. Every figure below is from live
reads on this VPS against the running gateway, the running sidecar and Photon's own API.
Phone numbers are redacted. No iMessage was sent as Nish.

## Impact

Nish's iMessage at about 23:37 IST on 2026-10-08 never reached Hermes, so nothing replied.
The inbound gRPC stream has not delivered a single event since the gateway started at
23:33:44, and `/healthz` still reports `state: "starting"` with `lastHealthyAt: null`.

This is a diagnostic write-up, not a fix. The failing code is the `hermes-agent` Photon sidecar
in a third-party checkout, which this repo does not own and this run did not modify.

## The live state

The unit is running and has never restarted, so nothing recovered it on its own:

```
$ systemctl show hermes-gateway.service -p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp -p Result
Result=success
NRestarts=0
ExecMainStartTimestamp=Thu 2026-10-08 23:33:44 IST 2026-10-08
ActiveState=active
SubState=running
```

The sidecar's health endpoint reports a stream that never went live. The token is passed in a
header file so it never reaches process arguments:

```
$ curl -s -X POST http://127.0.0.1:8789/healthz -H @/run/hermes/hermes-sidecar-headers
{
  "ok": true,
  "stream": {
    "ok": true,
    "state": "starting",
    "lastHealthyAt": null,
    "restartAfterMs": 90000,
    "lastIssueAt": null,
    "staleness": {
      "lastInboundAt": "2026-10-08T18:03:49.024Z",
      "silentForMs": 1122598,
      "silenceThresholdMs": 600000,
      "lastProbeAt": "2026-10-08T18:18:50.593Z",
      "lastProbeOutcome": "inconclusive",
      "zombieSuspected": false
    }
  }
}
```

Five lines carry the story:

- `state` is still `starting` and `lastHealthyAt` is `null`. The healthy callback only fires
  inside the inbound iterator body, so the stream has never produced one event since boot.
- `silentForMs` has passed `silenceThresholdMs`, so the watchdog is awake and probing.
- `lastProbeOutcome` is `inconclusive`, every time.
- `zombieSuspected` is `false`, and it cannot become `true`.

`lastInboundAt` is initialized to the process start time and only moves when the iterator
yields. Its value, 18:03:49 UTC, is five seconds after the unit started at 18:03:44 UTC. That
five-second offset is the process start, not traffic, and it is the proof that no event has
ever been yielded.

The log agrees, and the absence is the evidence. There is not one `[spectrum.stream]` line on
2026-10-08. The last one anywhere is 2026-10-03 15:26, the earlier outage that this same
watchdog also failed to act on:

```
$ awk '$1=="2026-10-08"' ~/.hermes/logs/gateway.log | grep -c 'spectrum.stream'
0
$ grep 'spectrum.stream' ~/.hermes/logs/gateway.log | tail -1 | cut -c1-19
2026-10-03 15:26:03
```

The behaviour is not pinned to this host's checkout. It was reproduced at this revision:

```
$ git -C ~/.hermes/hermes-agent rev-parse --short HEAD
ec24378   # NousResearch/hermes-agent
           # @spectrum-ts/core 12.7.0, @photon-ai/advanced-imessage 2.1.0 (sidecar install)
```

## Root cause, stated precisely

There are two separate failures and they must not be merged.

**1. The stream never opened. Cause unknown.** This is the outage. Nothing in the available
evidence says why. The stream is quiet rather than erroring, so a hung subscription and a
Photon-side relay outage look identical from here, and the only instrument that could tell
them apart is broken. The last recorded upstream error, from 2026-10-03, was
`ConnectionError: upstream connect error or disconnect/reset before headers`. No such error
exists for 2026-10-08. Any of the three candidate causes below would explain the evidence and
none is confirmed:

- a Photon-side shared-line relay outage,
- a provider-side subscription defect on this project,
- the subscription silently failing to establish at connect time.

This cannot be resolved from this host. The discriminator is a live iMessage from Nish, which
is his to send and was not sent on this run.

**2. The recovery path is broken. Cause proven.** The watchdog exists to catch a half-open
stream, and it can never fire, so failure 1 has no path out.

`zombieWatchdogTick()` in `sidecar/index.mjs` wakes once silence passes
`STREAM_SILENCE_PROBE_MS` (10 min by default) and calls `probeUpstream()`, a cheap unary read
over the same channel:

```js
const probeId = createProbeMessageId();
const space = await im.space.get(PROBE_SPACE_ID);
await space.getMessage(probeId);
```

`createProbeMessageId()` in `sidecar/stream-staleness.mjs` returns a bare `randomUUID()`. The
server does not accept it. Reproduced against the real credentials, on the real production code
path:

```
probe id shape : 5158c071-df45-4641-90a8-eb98da9ec4f2
error          : ValidationError | grpcCode: 3 | retryable: false
message        : [spectrum-imessage] Expected message resource GUID
watchdog verdict: {"alive":false,"inconclusive":true,...}
```

gRPC status 3 is `INVALID_ARGUMENT`, raised server-side, so it is permanent rather than
transient. Then the decision rule closes the chain:

1. The probe asks for a synthetic guid.
2. The server rejects that guid as invalid input.
3. `classifyProbeRejection()` only credits a not-found as proof the wire is alive, so this is
   inconclusive, never alive.
4. Inconclusive means take no action. The comment at `index.mjs:789` says it outright:
   `// Inconclusive: deliberately no action (see block comment above).`
5. Silence keeps waking the watchdog, every probe rejects the same way, and nothing restarts.

A probe whose id the server refuses can never produce the round-trip the watchdog accepts, so
the only evidence it will ever look for is unreachable by construction.

Not every id shape fails, and that is what makes this an SDK bug rather than a guess. All of
these are rejected identically with `Expected message resource GUID`: uuid-v4, `spc-`-prefixed,
`messages/`-prefixed, iMessage-prefixed, uuid-v1, nil uuid, chat-prefixed nil. Meanwhile the
*same* uuid is accepted over Photon's HTTP twin, which returns a clean 404 rather than a
validation error:

```
$ GET https://spectrum.photon.codes/v1/messages/79a62dfd-...-b29145e70cd2
HTTP 404  {"succeed":false,"data":null,"code":"NOT_FOUND","message":"Not found"}
```

So the credential and the id shape are both fine and the gRPC validator disagrees with the
REST validator about what a message guid is.

The classifier is not at fault. Run against the error shapes the SDK actually raises:

```
real SDK NotFoundError        -> {"alive":true,"inconclusive":false,...}
grpc NOT_FOUND (code string)  -> {"alive":true,"inconclusive":false,...}
grpc NOT_FOUND (numeric only)-> {"alive":false,"inconclusive":true,...}
live probe failure            -> {"alive":false,"inconclusive":true,...}
```

**What a fixed probe would and would not buy.** Being exact here, because it changes the
recommendation. `isZombieSuspect()` firing leads to `markStreamDegraded()`, which schedules
`process.exit(75)` 90 s later so systemd restarts the adapter. That is a restart on
*suspicion of a half-open socket*, not a verified stream recovery: a unary probe proves API
reachability, it does not prove the subscription is healthy. So fixing the probe id restores the
**recovery path**, and for this particular outage the stream never opened in the first place,
so the probe proves reachability and the exit-75 restart is what would actually retry the
subscription. A working probe is necessary but not sufficient on its own, and it should not be
sold as the complete fix.

## What is not the cause

**spectrum-ts version.** The sidecar pins 12.7.0 and 12.10.1 is the latest published.
Installed 12.10.1 into a clean tree and re-ran the same probe:

```
spectrum-ts version under test: 12.10.1
randomUUID -> ValidationError | grpcCode: 3 | [spectrum-imessage] Expected message resource GUID
nil-uuid   -> ValidationError | grpcCode: 3 | [spectrum-imessage] Expected message resource GUID
```

Identical. An upgrade will not restore the stream, and this is not a missed upgrade.

**Credentials and project registration.** Both work. `Spectrum()` starts cleanly against the
stored project id and secret, and the project's user and assigned line are intact (numbers
redacted):

```
$ GET https://spectrum.photon.codes/projects/<id>/users/
{"succeed":true,"data":{"users":[{"phoneNumber":"+91…7902",
  "assignedPhoneNumber":"+1…7704","meta":{"opt_in":true,"project_owner":true},...}]}}

$ GET https://spectrum.photon.codes/projects/<id>/lines/
{"succeed":true,"data":{"lines":[]}}
```

The empty `lines` array is expected for a shared-number plan and is not the fault. The operator
number is registered, opted in, and owns the project.

**The classifier.** Sound, as shown above.

**The model 429.** A separate cause at 23:35, reported in the same issue. A free-quota 429
blocks a reply even when a message does arrive. It is not the reason the message was missed.

## Where the fix belongs

Not in this repo. fleet-ops has no Photon reference at all and owns only the systemd unit that
starts the gateway. The files needing a change are in the `hermes-agent` checkout, a
third-party repository with no Nishfleet fork, so this run did not modify them.

The work splits the same way the two failures do:

- **For failure 1**, nothing to fix locally. It needs either an authorised test iMessage from
  Nish, which is his to send, or Photon-side shared-line relay and subscription diagnostics from
  the vendor. Until one of those lands, the cause stays unknown.
- **For failure 2**, the minimal durable fix is to give the probe an id the server will parse,
  so a round-trip completes and the existing decision rules work as designed. Note the
  evidence above does *not* identify such an id; that has to be established against the SDK or
  with Photon before the change is written. Failing that, the watchdog needs a liveness signal
  that is not a synthetic-guid read, because any probe the server refuses cannot drive it.
  Whoever writes it should cover it with the existing unit tests at
  `tests/plugins/platforms/photon/test_zombie_stream_watchdog.py`.

**Expected behaviour of a manual restart, not a measurement.** Until the probe is fixed, the
way out is a manual restart of `hermes-gateway.service`. That is the designed recovery path:
the unit exits 75, systemd restarts the adapter, and the subscription is retried from a fresh
process. This run did not restart the gateway, so no before-and-after measurement exists and
none is claimed here. Restarting clears the current hang but not the watchdog defect, so the
same failure can recur.

## Note on the model 429

Covered above under "What is not the cause". It is a distinct problem from the stream failure
and fixing it would not have restored this stream.

## What was not done

No iMessage was sent as Nish. His test message is the one that was already missed, and
re-sending it is his call. The sidecar was not restarted, so the evidence above is the state as
found and remains reproducible. No credential was printed, and the sidecar token in the health
example is read from a protected header file rather than from process arguments.