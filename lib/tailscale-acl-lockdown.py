#!/usr/bin/env python3
"""Prove the VPS cannot reach the Mac in the compiled Tailscale PacketFilter.

fleet-ops#544 / ledger 2026-08-24 Tailscale. Grants are deny-by-default.
The live netmap PacketFilter is the compiled policy (official Tailscale
docs: inspect PacketFilter via `tailscale debug netmap`). A rule whose
sources overlap this node and whose dests overlap the Mac is the class
this canary exists to catch (pasting acl-draft.json would loosen grants).

Usage:
  python3 lib/tailscale-acl-lockdown.py verify --netmap NETMAP.json --config CFG.json
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import sys
from typing import Any

Net = ipaddress.IPv4Network | ipaddress.IPv6Network


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be an object")
    return data


def parse_net(raw: str) -> Net:
    text = (raw or "").strip()
    if not text:
        raise ValueError("empty CIDR")
    if "/" not in text:
        addr = ipaddress.ip_address(text)
        return ipaddress.ip_network(f"{addr}/{addr.max_prefixlen}")
    return ipaddress.ip_network(text, strict=False)


def nets_overlap(left: list[Net], right: list[Net]) -> bool:
    for a in left:
        for b in right:
            if a.version == b.version and a.overlaps(b):
                return True
    return False


def node_blob(node: dict[str, Any]) -> str:
    parts = [
        str(node.get("Name") or ""),
        str(node.get("ComputedName") or ""),
        str(node.get("ComputedNameWithHost") or ""),
    ]
    return " ".join(parts).lower()


def node_matches(node: dict[str, Any], needles: list[str]) -> bool:
    blob = node_blob(node)
    return any(needle.lower() in blob for needle in needles if needle.strip())


def node_nets(node: dict[str, Any]) -> list[Net]:
    nets: list[Net] = []
    for raw in node.get("Addresses") or []:
        if isinstance(raw, str) and raw.strip():
            nets.append(parse_net(raw))
    return nets


def collect_src_nets(rule: dict[str, Any]) -> list[Net]:
    nets: list[Net] = []
    for raw in list(rule.get("Srcs") or []) + list(rule.get("SrcIPs") or []):
        if isinstance(raw, str) and raw.strip():
            nets.append(parse_net(raw))
    return nets


def collect_dst_nets(rule: dict[str, Any]) -> list[Net]:
    nets: list[Net] = []
    for dst in rule.get("Dsts") or []:
        if isinstance(dst, dict) and isinstance(dst.get("Net"), str):
            nets.append(parse_net(dst["Net"]))
        elif isinstance(dst, str) and dst.strip():
            nets.append(parse_net(dst))
    for dst in rule.get("DstPorts") or []:
        if isinstance(dst, dict) and isinstance(dst.get("IP"), str):
            nets.append(parse_net(dst["IP"]))
    return nets


def load_needles(cfg: dict[str, Any], key: str) -> list[str]:
    raw = cfg.get(key)
    if not isinstance(raw, list) or not raw:
        raise ValueError(f"config {key} must be a non-empty array of strings")
    needles = [str(item).strip() for item in raw if str(item).strip()]
    if not needles:
        raise ValueError(f"config {key} must be a non-empty array of strings")
    return needles


def verify_netmap(netmap: dict[str, Any], cfg: dict[str, Any]) -> list[str]:
    """Return error strings. Empty = lockdown holds."""
    errors: list[str] = []
    try:
        self_needles = load_needles(cfg, "self_name_needles")
        mac_needles = load_needles(cfg, "mac_name_needles")
    except ValueError as exc:
        return [f"WATCHER-BROKEN: {exc}"]

    self_node = netmap.get("SelfNode")
    if not isinstance(self_node, dict):
        return ["WATCHER-BROKEN: netmap missing SelfNode"]
    if not node_matches(self_node, self_needles):
        return [
            "WATCHER-BROKEN: SelfNode name does not match self_name_needles "
            f"{self_needles!r} (refusing to judge lockdown off the VPS)"
        ]
    self_nets = node_nets(self_node)
    if not self_nets:
        return ["WATCHER-BROKEN: SelfNode has no Addresses"]

    mac_node = None
    for peer in netmap.get("Peers") or []:
        if isinstance(peer, dict) and node_matches(peer, mac_needles):
            mac_node = peer
            break
    if mac_node is None:
        return [
            "WATCHER-BROKEN: no Peer matches mac_name_needles "
            f"{mac_needles!r}; cannot prove VPS→Mac is denied"
        ]
    mac_nets = node_nets(mac_node)
    if not mac_nets:
        return ["WATCHER-BROKEN: Mac peer has no Addresses"]

    rules: list[dict[str, Any]] = []
    for key in ("PacketFilter", "PacketFilterRules"):
        block = netmap.get(key)
        if block is None:
            continue
        if not isinstance(block, list):
            return [f"WATCHER-BROKEN: {key} must be an array"]
        for item in block:
            if isinstance(item, dict):
                rules.append(item)

    if "PacketFilter" not in netmap and "PacketFilterRules" not in netmap:
        return ["WATCHER-BROKEN: netmap has neither PacketFilter nor PacketFilterRules"]

    for idx, rule in enumerate(rules):
        try:
            srcs = collect_src_nets(rule)
            dsts = collect_dst_nets(rule)
        except ValueError as exc:
            errors.append(f"WATCHER-BROKEN: rule {idx} unparsable: {exc}")
            continue
        if nets_overlap(srcs, self_nets) and nets_overlap(dsts, mac_nets):
            errors.append(
                f"LOCKDOWN-BROKEN: PacketFilter rule {idx} allows this VPS as "
                "src toward the Mac dst (grants lockdown is gone; do not paste "
                "acl-draft.json)"
            )
    return errors


def cmd_verify(args: argparse.Namespace) -> int:
    try:
        netmap = load_json(args.netmap)
        cfg = load_json(args.config)
    except (OSError, ValueError) as exc:
        print(f"WATCHER-BROKEN: cannot load input: {exc}", file=sys.stderr)
        return 1
    errors = verify_netmap(netmap, cfg)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print("TAILSCALE-ACL-LOCKDOWN-OK: compiled PacketFilter has no VPS→Mac allow")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("verify", help="fail if compiled filter allows VPS→Mac")
    p.add_argument("--netmap", required=True, help="tailscale debug netmap JSON")
    p.add_argument("--config", required=True, help="lockdown needle config JSON")
    p.set_defaults(func=cmd_verify)
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
