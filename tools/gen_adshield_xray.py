#!/usr/bin/env python3
"""Generate the AdShield Xray fragment assets for IPChakra.

Reads the standalone AdShield (v0.6.1 EXTREME) bundled domain lists and
produces the two assets the app's V2Ray engine consumes at connect time:

  app/assets/adshield/xray_hosts.json  {"domain:<d>": "0.0.0.0", ...}
  app/assets/adshield/meta.json        {"domains": N, "source": ..., ...}

Parsing mirrors AdShield's AdBlocker.parseDomainSet exactly (strip,
lowercase, strip surrounding dots, skip '#' comments, keep lines that
contain a dot and no space or slash), plus the intent-fix for mangled
hosts-file lines ('0.0.0.0.creative.hpyrdr.com' -> 'creative.hpyrdr.com'),
plus a suffix-dedupe (a domain whose parent suffix is already listed is
dropped — Xray's 'domain:' matcher covers subdomains anyway).

Run from the repository root. Idempotent.
"""

import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = "/tmp/adshield-src/AdShield/app/src/main/assets"
OUT_DIR = os.path.join(REPO, "app", "assets", "adshield")

INPUTS = [
    "blocklist.txt",
    "network_blocklist.txt",
    "ad_networks.txt",
    "ublock_domains.txt",
    "hagezi_domains.txt",
    "streaming_safe_rules.txt",
    "streaming_blocklist.txt",
]


def parse_domain_set(lines):
    """Port of AdShield's AdBlocker.parseDomainSet + intent-fix."""
    parsed = set()
    for raw in lines:
        d = raw.strip().lower().strip(".")
        if d.startswith("#"):
            continue
        if d and "." in d and " " not in d and "/" not in d:
            # Intent-fix: mangled hosts-file lines ('0.0.0.0.<d>').
            if d.startswith("0.0.0.0."):
                d = d[len("0.0.0.0.") :]
            elif d.startswith("127.0.0.1."):
                d = d[len("127.0.0.1.") :]
            # The intent-fix must not create a dot-less entry.
            if d and "." in d and " " not in d and "/" not in d:
                parsed.add(d)
    return parsed


def suffix_dedupe(domains):
    """Drop domains whose parent suffix is already in the set."""
    kept = set()
    # Shortest first, so parent domains are kept and children dropped.
    for d in sorted(domains, key=lambda x: (x.count("."), x)):
        labels = d.split(".")
        redundant = any(".".join(labels[i:]) in kept for i in range(1, len(labels)))
        if not redundant:
            kept.add(d)
    return kept


def main():
    raw_lines = 0
    parsed = set()
    for name in INPUTS:
        path = os.path.join(SRC, name)
        if not os.path.exists(path):
            print(f"missing input (skipped): {path}", file=sys.stderr)
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
        raw_lines += len(lines)
        parsed |= parse_domain_set(lines)

    deduped = suffix_dedupe(parsed)

    os.makedirs(OUT_DIR, exist_ok=True)
    hosts_path = os.path.join(OUT_DIR, "xray_hosts.json")
    with open(hosts_path, "w", encoding="utf-8") as f:
        json.dump(
            {f"domain:{d}": "0.0.0.0" for d in sorted(deduped)},
            f,
            sort_keys=True,
            separators=(",", ":"),
        )
        f.write("\n")

    meta_path = os.path.join(OUT_DIR, "meta.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "domains": len(deduped),
                "source": "AdShield v0.6.1 EXTREME",
                "generated": "2026-10-11",
            },
            f,
            indent=2,
        )
        f.write("\n")

    # The old text lists are no longer assets; delete them if present.
    for stale in ("blocklist.txt", "streaming_blocklist.txt"):
        p = os.path.join(OUT_DIR, stale)
        if os.path.exists(p):
            os.remove(p)
            print(f"deleted stale asset: {p}")

    hosts_bytes = os.path.getsize(hosts_path)
    print(f"raw lines:      {raw_lines}")
    print(f"parsed unique:  {len(parsed)}")
    print(f"after dedupe:   {len(deduped)}")
    print(f"xray_hosts.json: {hosts_bytes} bytes")
    print(f"meta.json:      {os.path.getsize(meta_path)} bytes")


if __name__ == "__main__":
    main()
