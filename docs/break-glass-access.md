# Break-glass access (netcup VNC)

fleet-ops#455, access plane. SSH on this VPS is Tailscale-only. If
tailscaled is down, SSH is gone. The out-of-band layer is the netcup
provider VNC console. It exists today. Zero extra spend.

This file must never contain passwords, API tokens, or console URLs with
embedded credentials.

## When to use it

- tailscaled will not come back (`Restart=always` already applied and
  still down)
- the box is up but the Tailscale interface is gone
- you need to confirm sshd still binds only on Tailscale addresses

Do not use VNC for routine work.

## Steps

1. Open the netcup customer panel in a browser that does not depend on
   this VPS (phone, laptop, a network that is not Tailscale).
2. Open the VPS VNC console. Login as nish at the Linux prompt.
3. Check tailscaled:

   ```
   systemctl status tailscaled
   systemctl restart tailscaled
   tailscale status
   ```

4. Confirm SSH is still not public:

   ```
   ss -ltn | grep ':22'
   ```

   Expect Tailscale addresses only (`100.*` or `fd7a:*`). A line showing
   `0.0.0.0:22` or `[::]:22` is a public SSH bind. Fix that before you
   disconnect. The ACL lockdown stays: no public SSH.

5. From another machine, `ssh` over Tailscale. If that works, leave VNC.

## What this is not

- Not a second SSH listener on a public port.
- Not a standing open console session.
- Not an automated kill of live tailscaled. That kill is a Nish game-day
  with a human already on VNC, so a failed restart cannot lock everyone
  out.

## Credentials

Panel login lives in Nish's password manager, not in this repo, not in
the vault. If the panel login is lost, that is a Nish call (money /
provider account), not a worker ticket.
