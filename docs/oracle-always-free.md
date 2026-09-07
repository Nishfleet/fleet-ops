# Oracle Cloud Always Free — outside-in monitor + tailnet spare

**Why this exists.** The netcup VPS (`netcup-rs2000`, public `159.195.212.168`)
is the fleet's only host, and its inbound firewall allows **nothing** except
`tailscale0`. That makes it un-probeable from the public internet on purpose —
and it also means a box that is up but wedged looks identical to a box that is
gone, from anywhere outside the tailnet. healthchecks.io holds a dead-man
check, which catches "the fleet stopped pinging", but nothing measures the host
or the product sites from *outside*.

An OCI Always Free node fixes exactly that, and only that: it sits outside
netcup's network, joins the tailnet so it *can* reach netcup's SSH and ICMP,
and runs Uptime Kuma. As a second effect it is a spare tailnet node — an
emergency SSH bastion if netcup's Tailscale ever dies while ufw stays shut.

**Cost: $0.** Everything below is inside Oracle's Always Free allowance
(2x VM.Standard.E2.1.Micro, plus **2 OCPU / 12 GB** of VM.Standard.A1.Flex,
plus 200 GB of block storage across *all* volumes, plus 10 TB/month egress).
Nothing here upgrades to Pay As You Go. Backups stay on Cloudflare R2 — this
box is **not** a backup target.

> **The A1 allowance was cut from 4 OCPU / 24 GB to 2 OCPU / 12 GB.** Oracle
> surfaces this as a console banner, "Always Free A1 Resource Limit Update",
> and it is confirmed in the Always Free docs (checked 2026-09-07). Older
> guides — and the first version of this one — still say 4/24. They are wrong
> now, and acting on them costs money.

---

## Status

| Piece | State |
|---|---|
| OCI CLI on netcup | **installed** — `oci` 3.92.0 at `~/.local/bin/oci` (venv at `~/.local/share/oci-cli-venv`) |
| `~/.oci/config` + API key | **BLOCKED on Nish** — Oracle signup needs a card |
| `oracle-arm-fish.timer` | **live**, ticking every 10 min, standing down cleanly until credentials exist |
| micro instance | pending credentials |
| Uptime Kuma | pending instance |

---

## Nish's steps (the card is the only hard stop)

1. **Sign up** at <https://cloud.oracle.com/free>. A credit/debit card is
   required for identity verification; Oracle does not charge it on the free
   tier. That field is Nish's alone.

2. **Home region is permanent and cannot be changed later.** It decides whether
   ARM capacity is ever available. Busy regions — Mumbai, Singapore, Frankfurt,
   Ashburn — are near-permanently out of A1 capacity.

   **Pick `ap-hyderabad-1` (Hyderabad).** India-local so latency to Nish and to
   the India-facing products is low, and it is far quieter than Mumbai. Second
   choice `ap-osaka-1` (Osaka). Other quiet options: Chuncheon, Jerusalem,
   Marseille.

   Latency to netcup does not matter here — the monitor measures *reachability*,
   not speed.

3. **Mint an API key:** Profile (top right) -> **My profile** -> **API keys** ->
   **Add API key** -> *Generate API key pair* -> **Download private key** ->
   Add. Oracle then shows a **configuration file preview**. Hand over both:
   the downloaded `.pem` and that preview text (it contains `user`, `fingerprint`,
   `tenancy`, `region`, `key_file`). None of it is a password; it is an
   asymmetric key pair scoped to the tenancy.

4. **Mint a Tailscale auth key:** <https://login.tailscale.com/admin/settings/keys>
   -> *Generate auth key* -> **Reusable yes, Ephemeral no, 90 days**. Needed to
   join the Oracle boxes to the tailnet without an interactive browser login.

5. **Do NOT upgrade to Pay As You Go.** If ARM has not landed after 7 days of
   fishing, that becomes a real question — PAYG massively raises A1 allocation
   success while leaving the Always Free resources free — but it turns billing
   on, so it is Nish's call and nobody else's.

### Installing what he hands back

```bash
mkdir -p ~/.oci && chmod 700 ~/.oci
mv ~/Downloads/<downloaded>.pem ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key.pem
$EDITOR ~/.oci/config          # paste the preview; key_file=/home/nish/.oci/oci_api_key.pem
chmod 600 ~/.oci/config
oci iam region list --query 'data[0]' && oci iam availability-domain list
```

---

## Day one: the micro instance

`VM.Standard.E2.1.Micro` (x86, 1 OCPU, 1 GB) is Always Free and, unlike A1,
almost always has capacity. One command:

```bash
oracle-bootstrap-micro
```

Idempotent — it looks every object up by display name and only creates what is
missing, so a partial failure is resumed by re-running it.

It builds `fleet-monitor-vcn` (10.10.0.0/16) with a public subnet, an internet
gateway, and a security list whose **entire** public ingress is:

* `tcp/22` from `159.195.212.168/32` — the netcup VPS and nothing else
* `udp/41641` from anywhere — Tailscale's direct path. Without it Tailscale
  still works, but relays every packet through a DERP server.

The Uptime Kuma web UI is **never** exposed publicly; it is reached over the
tailnet. On success the script writes `~/.oci/fleet-arm.env`, which is what
`oracle-arm-fish` waits for.

### Join the tailnet

```bash
ssh ubuntu@<public-ip>
sudo tailscale up --auth-key=<tailscale auth key> --hostname=oracle-monitor --ssh
```

Then prove it in both directions: `tailscale ping oracle-monitor` from netcup,
and `tailscale ping netcup-rs2000` from the Oracle box.

### Swap first

1 GB of RAM will OOM during Uptime Kuma's build step. Add swap before anything
else:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### Uptime Kuma

1 GB is genuinely tight for Docker, so prefer the bare Node install:

```bash
sudo apt-get update && sudo apt-get install -y nodejs npm git
sudo useradd -m -r kuma || true
sudo -u kuma git clone https://github.com/louislam/uptime-kuma.git /home/kuma/uptime-kuma
cd /home/kuma/uptime-kuma && sudo -u kuma npm run setup
```

Then write `/etc/systemd/system/uptime-kuma.service` with a `simple` service
running `/usr/bin/node server/server.js` as `User=kuma`, working directory
`/home/kuma/uptime-kuma`, `Restart=on-failure`, and enable it. Reach the UI at
`http://oracle-monitor:3001` over the tailnet. Public `3001` stays closed at
the security list — the admin UI never faces the internet.

### Monitors to add

| Monitor | Type | Target |
|---|---|---|
| netcup — ICMP | Ping | `100.108.184.97` (its Tailscale IP; public ICMP is firewalled) |
| netcup — SSH | TCP Port | `100.108.184.97:22` |
| 0509.io | HTTP(s) | `https://0509.io/` |
| 0509.in | HTTP(s) | `https://0509.in/` (308 -> follow redirects) |
| inish.in | HTTP(s) | `https://inish.in/` |
| aiconverter.app | HTTP(s) | `https://aiconverter.app/` |
| seofixkit.com | HTTP(s) | `https://seofixkit.com/` |
| siterep.net | HTTP(s) | `https://siterep.net/` |
| tinystudio.in | HTTP(s) | `https://tinystudio.in/` |
| tinystudio.io | HTTP(s) | `https://tinystudio.io/` |
| healthchecks dead-man | HTTP(s) | the fleet's healthchecks.io ping URL |

All eight product domains were verified live (HTTP 200; `0509.in` 308-redirects)
on 2026-09-07.

**Notifications:** Telegram. The long-lived bot token already used by
`nish-boundary-notify` lives under `/home/nish/.claude-telegram/` — read the
token and chat id from there at install time. Never paste either into a repo, a
vault note, or a log line.

### Back on netcup

```bash
sudo ufw allow from <oracle tailscale ip> to any port 22 proto tcp comment 'oracle-monitor bastion'
sudo ufw status numbered
```

ufw rule 1 already allows everything on `tailscale0`, so this is belt-and-braces:
it survives someone narrowing rule 1 later.

---

## ARM fishing

`VM.Standard.A1.Flex` is the valuable half of Always Free, and it is "Out of
host capacity" in most regions most of the time. There is no waitlist and no
event to subscribe to. Repeated `LaunchInstance` calls are the only documented
route in.

**The allowance is 2 OCPU / 12 GB, and it is metered by the hour, not by
shape:** 1,500 OCPU-hours and 9,000 GB-hours per month. Divide by a 730-hour
month and that is 2.05 OCPU and 12.3 GB — i.e. exactly 2/12 running
continuously, with almost no headroom. A larger shape does not fail at launch
and bill you later; it drains the monthly budget early and starts charging
partway through the month, quietly. **2/12 is the ceiling, not an opening bid,
and there is nothing to resize up to.**

`oracle-arm-fish` refuses to launch above 2 OCPU / 12 GB / 150 GB boot and
exits 1 (`state=error reason=exceeds-always-free`). The knobs are
env-overridable downward only — nothing can grow the ask past the free ceiling
by accident.

* `oracle-arm-fish` is **one ask**, not a loop. `oracle-arm-fish.timer` owns
  the repetition (fleet rule: no hand-built dispatchers in bash).
* **Every 10 minutes, deliberately.** Oracle rate-limits `LaunchInstance` and
  has revoked Always Free tenancies for hammering it. Faster is not better;
  faster loses the account.
* It asks for **2 OCPU / 12 GB** — the entire allowance, in one instance.
* It rotates across every availability domain in the home region each tick.
* **It disables itself** the moment an instance reaches RUNNING, and appends an
  informational line to `NISH-ESCALATIONS.md`.

Verdict lines (`journalctl --user -u oracle-arm-fish`), because exit 0 is not
proof of success:

```
ARM-FISH-VERDICT state=standdown   no credentials yet; nothing attempted
ARM-FISH-VERDICT state=nocapacity  asked every AD; all out of host capacity  (expected)
ARM-FISH-VERDICT state=landed      RUNNING; timer disabled itself
ARM-FISH-VERDICT state=error       a real fault -> exit 1 -> OnFailure summons repair
```

"Out of host capacity" exits **0**, so the expected miss never pages anyone.

After it lands: **do not resize it up** — 2/12 is already the whole allowance.
Join it to the tailnet the same way as the micro, and add it to ufw.

**Block volume arithmetic.** Always Free is 200 GB across *every* volume, and
each instance takes a boot volume (47 GB minimum, 50 GB default). The budget
here is the micro's 50 GB plus the ARM node's 100 GB = 150 GB, leaving 50 GB
spare. Do not grow either boot volume to 200 GB — that alone consumes the whole
allowance and puts the other instance's disk into billing.

---

## The reclamation trap

Oracle reclaims **idle** Always Free compute: roughly, an instance averaging
under 20% CPU, 20% network *and* 20% memory over a 7-day window becomes
eligible for reclamation. (Instances in a tenancy that has ever been upgraded
to PAYG are exempt.)

Uptime Kuma is what keeps this box above the bar — a node running dozens of
active probes on a short interval is not idle. That is a real reason to put the
monitor on this box rather than parking an empty spare. Do not "tidy up" by
lowering the probe frequency to near-nothing; that is how the node gets
reclaimed. If the ARM node lands and has no job, give it one.
