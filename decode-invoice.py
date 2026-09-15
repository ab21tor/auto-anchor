#!/usr/bin/env python3
"""Print "<sats> <paymentHash>" from a phoenixd /decodeinvoice answer read
from stdin, or nothing at all, which every caller treats as "refuse to pay".

The amount follows decode-amount.py's rule (amountSat, then amount in
millisats, then amountMsat; fail closed on anything else). The payment hash
must be present and 64 hex (lowercased here): a payer that cannot read the
invoice's own payment hash cannot check the preimage it is handed, so it
does not pay. Shared by pay-anchor-bills.sh and pay402 (2026-09-15)."""
import importlib.util
import json
import os
import re
import sys

_spec = importlib.util.spec_from_file_location(
    "decode_amount", os.path.join(os.path.dirname(os.path.abspath(__file__)), "decode-amount.py"))
_decode_amount = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_decode_amount)
sats = _decode_amount.sats

HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")


def main():
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return
    n = sats(d)
    h = d.get("paymentHash") if isinstance(d, dict) else None
    if n and isinstance(h, str) and HEX64.match(h):
        print("%d %s" % (n, h.lower()))


if __name__ == "__main__":
    main()
