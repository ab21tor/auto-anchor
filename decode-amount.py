#!/usr/bin/env python3
"""Print the amount, in sats, of a phoenixd /decodeinvoice answer read from
stdin — or nothing at all, which every caller treats as "refuse to pay".

Precedence, the same everywhere in this project: amountSat, then amount
(millisats), then amountMsat. Anything unreadable, missing, non-positive
or not an integer prints nothing (fail closed). decode-invoice.py imports
the rule from here."""
import json
import sys


def sats(d):
    if not isinstance(d, dict):
        return None
    for key, divisor in (("amountSat", 1), ("amount", 1000), ("amountMsat", 1000)):
        v = d.get(key)
        if isinstance(v, bool) or not isinstance(v, int):
            if isinstance(v, str) and v.isdigit():
                v = int(v)
            else:
                continue
        if v > 0:
            return v // divisor
    return None


def main():
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return
    n = sats(d)
    if n:
        print(n)


if __name__ == "__main__":
    main()
