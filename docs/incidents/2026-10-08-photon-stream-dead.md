# 2026-10-08: the Photon iMessage stream never goes live, and the watchdog that should restart it is blind

Blameless. Times are IST unless marked UTC. The finding is from live reads on this VPS
against the running gateway, the running sidecar, and Photon's own API. No iMessage was sent
as Nish.

## Summary

Nish's iMessage at about 23:37 IST on 2026-10-08 never reached Hermes. The inbound gRPC
stream is not alive, and the mechanism built to detect exactly this failure cannot ever fire,
so nothing restarted it. The stream has never yielded a single event since the gateway started
at 23:33:44.

The watchdog is blind for a structural reason: its liveness probe asks the server for a
message id the server refuses to parse. The rejection is not transient, so the probe can
never succeed, and the watchdog's own rules say it must do nothing when the probe is
inconclusive. Silence plus a permanently inconclusive probe is exactly the state it is built
to ignore.

This is not a fleet-ops defect. fleet-ops ships no Photon code and installs
`hermes-gateway.service` as a unit file; the failing code is the `hermes-agent` sidecar in a
third-party checkout.

## What the live system says

`hermes-gateway.service` is running and has not restarted:

```
$ systemctl show hermes-gateway.service -p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp -p Result
Result=success
NRestarts=0
ExecMainStartTimestamp=Thu 2026-10-08 23:33:44 IST 2026-10-08
ActiveState=active
SubState=running
```

The sidecar's own health endpoint reports a stream that never went live:

```
$ curl -s -X POST http://127.0.0.1:8789/healthz -H "X-Hermes-Sidecar-Token: ..."
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
      "silentForMs": 906333,
      "silenceThresholdMs": 600000,
      "lastProbeAt": "2026-10-08T18:18:50.593Z",
      "lastProbeOutcome": "inconclusive",
      "zombieSuspected": false
    }
  }
}
```

Four lines of that carry the whole story:

- `state` is still `starting` and `lastHealthyAt` is `null`. In the sidecar the healthy
  callback only fires inside the inbound iterator body, so the stream has never produced one
  event since boot.
- `silentForMs` has passed `silenceThresholdMs`, so the watchdog is awake and probing.
- `lastProbeOutcome` is `inconclusive`, every time.
- `zombieSuspected` is `false`, and it cannot become `true`.

`lastInboundAt` is set to the process start time and only moves when the inbound iterator
yields. Its value, 23:33:49 IST, is one second after the unit started, which is itself the
proof that no event has ever been yielded.

The gateway log agrees, and the absence is the evidence. There is not one `[spectrum.stream]`
line on 2026-10-08. The last one anywhere is 2026-10-03 15:26, the earlier outage that this
same watchdog also failed to act on:

```
$ awk '$1=="2026-10-08"' ~/.hermes/logs/gateway.log | grep -c 'spectrum.stream'
0
$ grep 'spectrum.stream' ~/.hermes/logs/gateway.log | tail -1 | cut -c1-19
2026-10-03 15:26:03
```

## Root cause

The watchdog exists to catch a half-open socket, where the iterator hangs without erroring.
When the stream has been silent past `STREAM_SILENCE_PROBE_MS` (10 min by default) it calls
`probeUpstream()` in `sidecar/index.mjs`, which does a cheap unary read over the same channel:

```js
const probeId = createProbeMessageId();
const space = await im.space.get(PROBE_SPACE_ID);
await space.getMessage(probeId);
```

`createProbeMessageId()` in `sidecar/stream-staleness.mjs` returns a bare `randomUUID()`.
That id is not accepted by the server. Reproduced against the real credentials, on the real
production code path:

```
probe id shape : 5158c071-df45-4641-90a8-eb98da9ec4f2
error          : ValidationError | grpcCode: 3 | retryable: false
message        : [spectrum-imessage] Expected message resource GUID
watchdog verdict: {"alive":false,"inconclusive":true,...}
```

gRPC status 3 is `INVALID_ARGUMENT`, raised server-side by
`MessagesResource.get` in `@photon-ai/advanced-imessage`. It is not a network fault and not a
timeout, so it is permanent rather than transient.

Then the decision rule does the rest. `classifyProbeRejection()` only treats a not-found as
proof the wire is alive, and `zombieWatchdogTick()` documents the consequence in its own
comment: an inconclusive probe means do nothing, because the network may simply be down.

So the chain is closed:

1. The probe asks for a synthetic guid.
2. The server rejects that guid as invalid input.
3. The rejection classifies as inconclusive, never alive.
4. Inconclusive means take no action.
5. The stream stays dead, and the next probe rejects the same way.

A probe whose id the server refuses can never produce the round-trip the watchdog needs. The
only evidence it accepts is unreachable by construction. This is why the failure has been
silent since 23:33 rather than self-healing.

The probe id is not the only shape that fails. All of these are rejected identically:

```
uuid-v4           -> ValidationError | Expected message resource GUID
spc-uuid          -> ValidationError | Expected message resource GUID
msgs/prefix       -> ValidationError | Expected message resource GUID
iMessage-prefixed -> ValidationError | Expected message resource GUID
uuid v1           -> ValidationError | Expected message resource GUID
nil uuid          -> ValidationError | Expected message resource GUID
chat-prefixed nil -> ValidationError | Expected message resource GUID
```

The same uuid accepted over Photon's HTTP twin, which is worth recording because it shows the
credential and the id shape are both fine and the gRPC validator is the odd one out:

```
$ GET https://spectrum.photon.codes/v1/messages/79a62dfd-97d5-4909-9be9-b29145e70cd2
HTTP 404  {"succeed":false,"data":null,"code":"NOT_FOUND","message":"Not found"}
```

The classifier is not at fault. Run against the error shapes the SDK actually raises, it
returns alive for both a genuine `NotFoundError` and a NOT_FOUND carrying
`code:"notFound"`. Fixing the probe id is sufficient.

## What is not the cause

**spectrum-ts version.** The sidecar pins 12.7.0 and 12.10.1 is the latest published.
Installed 12.10.1 into a clean tree and re-ran the same probe:

```
spectrum-ts version under test: 12.10.1
randomUUID -> ValidationError | grpcCode: 3 | [spectrum-imessage] Expected message resource GUID
nil-uuid   -> ValidationError | grpcCode: 3 | [spectrum-imessage] Expected message resource GUID
```

Identical. An upgrade will not restore the stream.

**Credentials and project registration.** Both work. `Spectrum()` starts cleanly against the
stored project id and secret, and the project's user and assigned line are intact:

```
$ GET https://spectrum.photon.codes/projects/<id>/users/
{"succeed":true,"data":{"users":[{"phoneNumber":"+919873730902",
  "assignedPhoneNumber":"+16282647704","meta":{"opt_in":true,"project_owner":true},...}]}}

$ GET https://spectrum.photon.codes/projects/<id>/lines/
{"succeed":true,"data":{"lines":[]}}
```

The empty `lines` array is expected for a shared-number plan and is not the fault. The
operator number is registered, opted in, and owns the project.

**The Tincan move.** Not implicated. The failure is a rejected unary RPC and a stream that
never opened, with a project that authenticates fine.

## Where the fix belongs

Not in this repo. fleet-ops has no Photon reference at all, and owns only the systemd unit
that starts the gateway. The two files that need to change are in the `hermes-agent`
checkout, a third-party repository with no Nishfleet fork, so this run did not modify them.

The minimal durable fix is to give the probe an id the server will parse, so a round-trip
completes and the existing decision rules work as designed. The probe only needs a
well-formed read against a message that certainly does not exist; it does not need the
`randomUUID()` shape. Failing that, the watchdog needs a second liveness signal that is not
itself a synthetic-guid read, because any probe the server refuses cannot drive it.

Two things make this durable rather than a one-off: the sidecar already has a unit test for
these exact helpers (`tests/plugins/platforms/photon/test_zombie_stream_watchdog.py`), and
the watchdog's silence threshold is configurable. Until the probe is fixed, the only way to
recover this gateway is a manual restart, which clears the hung stream and starts a fresh
subscription.

## Note on the model 429

Separate cause, reported in the same issue. A model free-quota 429 at 23:35 blocks replies
even when a message does arrive. It is not the reason the message was missed, and fixing it
would not have restored this stream.

## What was not done

No iMessage was sent as Nish. His test message is the one that was already missed, and
re-sending it is his call. The sidecar was not restarted, so the evidence above is the state
as found and is still live for confirmation.