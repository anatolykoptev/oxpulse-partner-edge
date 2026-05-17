#!/usr/bin/env python3
"""Read xhttp transport fields from node-config.json with safe fallback.

Used by update.sh, channel-render-lib.sh, tests/test_xray_client_golden.sh
to avoid drift across three sites duplicating the same inline python heredocs.

Usage:
    read-xhttp.py <node-config.json> <field> [--default VALUE] [--type {str,int}]

Fields (read in priority order, first non-empty wins):
    mode             -> channels[0].xray.xhttp.mode, then channels[0].xray.mode, then default
    path             -> channels[0].xray.xhttp.path, then default
    xmux_concurrency -> channels[0].xray.xhttp.xmux.maxConcurrency, then channels[0].xray.xmux.maxConcurrency, then default
    xmux_reuse       -> channels[0].xray.xhttp.xmux.cMaxReuseTimes, then channels[0].xray.xmux.cMaxReuseTimes, then default
    xmux_lifetime    -> channels[0].xray.xhttp.xmux.cMaxLifetimeMs, then channels[0].xray.xmux.cMaxLifetimeMs, then default
    padding          -> channels[0].xray.xhttp.extra.xPaddingBytes, then default

In all cases the channels[0].xray subtree is only consulted when
channels[0].protocol == 'vless-reality'.  If no matching channel is
found, every field falls back to its --default value.

Exit codes:
    0 — success (value printed to stdout)
    2 — cannot parse config file (corrupt or missing)
"""
import argparse
import json
import sys
from typing import Any, Optional


def _ch0_xray(data: Any) -> dict:
    """Return channels[0].xray dict when protocol==vless-reality, else {}."""
    ch = data.get("channels", [])
    if ch and ch[0].get("protocol", "") == "vless-reality":
        return ch[0].get("xray", {})
    return {}


def read_field(data: Any, field: str) -> Optional[Any]:
    """Return the field value from data, or None if absent / empty string."""
    x = _ch0_xray(data)
    xhttp = x.get("xhttp", {})

    if field == "mode":
        v = xhttp.get("mode", "") or x.get("mode", "")
        return v if v else None

    if field == "path":
        v = xhttp.get("path", "")
        return v if v else None

    if field == "xmux_concurrency":
        xm = xhttp.get("xmux") or x.get("xmux") or {}
        v = xm.get("maxConcurrency")
        return v if v is not None else None

    if field == "xmux_reuse":
        xm = xhttp.get("xmux") or x.get("xmux") or {}
        v = xm.get("cMaxReuseTimes")
        return v if v is not None else None

    if field == "xmux_lifetime":
        xm = xhttp.get("xmux") or x.get("xmux") or {}
        v = xm.get("cMaxLifetimeMs")
        return v if v is not None else None

    if field == "padding":
        v = xhttp.get("extra", {}).get("xPaddingBytes", "")
        return v if v else None

    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="path to node-config.json")
    parser.add_argument(
        "field",
        choices=["mode", "path", "xmux_concurrency", "xmux_reuse", "xmux_lifetime", "padding"],
    )
    parser.add_argument("--default", default="", help="fallback value if field absent")
    parser.add_argument("--type", choices=["str", "int"], default="str")
    args = parser.parse_args()

    try:
        with open(args.config) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        # Fail-fast on parse error rather than silent fallback — corrupt
        # config should not be papered over with default xhttp settings.
        print(f"read-xhttp.py: cannot parse {args.config}: {e}", file=sys.stderr)
        return 2

    val = read_field(data, args.field)
    if val is None:
        val = args.default

    if args.type == "int":
        try:
            val = int(val)
        except (ValueError, TypeError):
            val = int(args.default) if args.default else 0

    print(val)
    return 0


if __name__ == "__main__":
    sys.exit(main())
