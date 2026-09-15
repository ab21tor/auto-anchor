#!/usr/bin/env python3
"""check-proof.py FILE DIGESTHEX

Exit 0 when FILE is one whole OpenTimestamps detached proof of DIGESTHEX:
the magic, version 1, a sha256 file-hash op, exactly that digest, then a
timestamp tree that parses to the last byte (every branch ending in an
attestation; no trailing bytes). Exit 1 with one line on stdout otherwise.
Structural: nothing is replayed or checked against Bitcoin — this is the
gate between "bytes an HTTP response carried" and "a proof file on disk"
(2026-09-15 review: pay402 saved a 503 body over an existing proof and
called any non-empty 200 body a proof). The format follows the fork's
ops/verify_claim.py parser."""
import sys

MAGIC = b'\x00OpenTimestamps\x00\x00Proof\x00\xbf\x89\xe2\xe8\x84\xe8\x92\x94'
ATTESTATION = 0x00
FORK = 0xff
UNARY = {0x02, 0x03, 0x08, 0x67, 0xf2, 0xf3}   # sha1 ripemd160 sha256 keccak256 reverse hexlify
BINARY = {0xf0, 0xf1}                            # append prepend


class Bad(Exception):
    pass


def varuint(data, pos):
    value, shift = 0, 0
    while True:
        if pos >= len(data):
            raise Bad("truncated")
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7f) << shift
        shift += 7
        if not byte & 0x80:
            return value, pos


def varbytes(data, pos):
    n, pos = varuint(data, pos)
    if pos + n > len(data):
        raise Bad("truncated")
    return pos + n


def timestamp(data, pos, found):
    while True:
        if pos >= len(data):
            raise Bad("truncated: no attestation")
        if data[pos] == FORK:
            pos = branch(data, pos + 1, found)
            continue
        return branch(data, pos, found)


def branch(data, pos, found):
    tag = data[pos]
    pos += 1
    if tag == ATTESTATION:
        if pos + 8 > len(data):
            raise Bad("truncated attestation")
        pos = varbytes(data, pos + 8)
        found.append(1)
        return pos
    if tag in BINARY:
        pos = varbytes(data, pos)
    elif tag not in UNARY:
        raise Bad("unknown op 0x%02x" % tag)
    return timestamp(data, pos, found)


def main():
    if len(sys.argv) != 3:
        print("usage: check-proof.py FILE DIGESTHEX")
        return 2
    try:
        data = open(sys.argv[1], "rb").read()
        digest = bytes.fromhex(sys.argv[2])
    except (OSError, ValueError) as exc:
        print("unreadable (%s)" % type(exc).__name__)
        return 1
    try:
        if data[:len(MAGIC)] != MAGIC:
            raise Bad("not an OpenTimestamps proof")
        pos = len(MAGIC)
        version, pos = varuint(data, pos)
        if version != 1:
            raise Bad("unsupported version %d" % version)
        if pos >= len(data) or data[pos] != 0x08:
            raise Bad("file hash op is not sha256")
        pos += 1
        if data[pos:pos + 32] != digest:
            raise Bad("proof is of a different digest")
        found = []
        end = timestamp(data, pos + 32, found)
        if end != len(data):
            raise Bad("trailing bytes after the proof")
        if not found:
            raise Bad("no attestation")
    except Bad as exc:
        print(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
