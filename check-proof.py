#!/usr/bin/env python3
"""check-proof.py FILE DIGESTHEX

Exit 0 when FILE is one whole OpenTimestamps detached proof of DIGESTHEX
by the public client's rules as this project's readers pin them (the
corpus in tests/proof_corpus.py, shared with the calendar fork and the
client adapter): the magic, version 1, a sha256 file-hash op, exactly
that digest, then a timestamp tree in which every branch ends in an
attestation, every known attestation payload is read to its last byte (a
pending URI: at most 1000 bytes of A-Z a-z 0-9 - . _ / :; a bitcoin
height: one varuint), an unknown tag's payload is skipped, and no byte is
left over. Two narrowings, as in the fork's readers: only the operations
a calendar emits (sha256, append, prepend) and a varuint of at most ten
bytes. Exit 1 with one line on stdout otherwise.

Structural: nothing is replayed or checked against Bitcoin. This is the
gate between "bytes an HTTP response carried" and "a proof file on disk"
(2026-09-15 review: pay402 saved a 503 body over an existing proof and
called any non-empty 200 body a proof; the same review's F03: the payload
of an attestation was skipped by its declared length, not read, so an
empty bitcoin payload passed here and failed the public client). The
format follows the fork's ops/verify_claim.py parser."""
import sys

MAGIC = b'\x00OpenTimestamps\x00\x00Proof\x00\xbf\x89\xe2\xe8\x84\xe8\x92\x94'
VERSION = 1
OP_SHA256 = 0x08
OP_APPEND = 0xf0
OP_PREPEND = 0xf1
ATTESTATION = 0x00
FORK = 0xff
PENDING_TAG = bytes.fromhex('83dfe30d2ef90c8e')
BITCOIN_TAG = bytes.fromhex('0588960d73d71901')
MAX_OPERAND = 4096
MAX_MSG = 4096
MAX_ATTESTATION_PAYLOAD = 8192
MAX_URI = 1000
URI_CHARS = frozenset(b'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:')
MAX_OPS_ON_A_PATH = 255
MAX_VARUINT_BYTES = 10


class Bad(Exception):
    """Bytes that are not one whole proof: refused, never guessed at."""


def varuint(data, pos):
    value, shift, start = 0, 0, pos
    while True:
        if pos >= len(data):
            raise Bad("truncated varuint")
        if pos - start >= MAX_VARUINT_BYTES:
            raise Bad("varuint longer than %d bytes" % MAX_VARUINT_BYTES)
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7f) << shift
        shift += 7
        if not byte & 0x80:
            return value, pos


def varbytes(data, pos, max_len, min_len=0):
    n, pos = varuint(data, pos)
    if n > max_len:
        raise Bad("varbytes longer than %d bytes" % max_len)
    if n < min_len:
        raise Bad("varbytes shorter than %d byte" % min_len)
    if pos + n > len(data):
        raise Bad("truncated varbytes")
    return data[pos:pos + n], pos + n


def attestation(data, pos):
    """The attestation whose marker byte was just read: ((kind, value),
    end). A known payload is read to its last byte; an unknown tag's
    payload is skipped and reported as ('unknown', tag hex)."""
    tag = data[pos:pos + 8]
    if len(tag) != 8:
        raise Bad("truncated attestation tag")
    pos += 8
    payload, pos = varbytes(data, pos, MAX_ATTESTATION_PAYLOAD)
    if tag == PENDING_TAG:
        uri, end = varbytes(payload, 0, MAX_URI)
        if end != len(payload):
            raise Bad("trailing bytes in the pending attestation")
        if any(b not in URI_CHARS for b in uri):
            raise Bad("pending uri has a character outside the allowed set")
        return ("pending", uri.decode("ascii")), pos
    if tag == BITCOIN_TAG:
        height, end = varuint(payload, 0)
        if end != len(payload):
            raise Bad("trailing bytes in the bitcoin attestation")
        return ("bitcoin", height), pos
    return ("unknown", tag.hex()), pos


def check(data, digest):
    """The attestations of one whole proof of `digest`, as (kind, value)
    pairs, or Bad. Only the shape is read: message lengths are tracked
    for the bounds, no hash is computed, nothing is replayed. The walk is
    a loop: a timestamp is zero or more fork-marked branches then a last
    branch, and every fork marker promises one more branch after the one
    it opens ends, so `pending` holds, per open fork, the message length
    and operation count the sibling branch resumes with."""
    if data[:len(MAGIC)] != MAGIC:
        raise Bad("not an OpenTimestamps proof")
    pos = len(MAGIC)
    version, pos = varuint(data, pos)
    if version != VERSION:
        raise Bad("unsupported version %d" % version)
    if pos >= len(data) or data[pos] != OP_SHA256:
        raise Bad("file hash op is not sha256")
    pos += 1
    if len(data) - pos < 32:
        raise Bad("truncated digest")
    if data[pos:pos + 32] != digest:
        raise Bad("proof is of a different digest")
    pos += 32
    found = []
    pending = []
    msg_len, ops, after_fork = 32, 0, False
    while True:
        if pos >= len(data):
            raise Bad("truncated: no attestation")
        tag = data[pos]
        pos += 1
        if tag == FORK:
            if after_fork:
                raise Bad("a fork marker followed by another fork marker")
            pending.append((msg_len, ops))
            after_fork = True
            continue
        after_fork = False
        if tag == ATTESTATION:
            node, pos = attestation(data, pos)
            found.append(node)
            if not pending:
                break
            msg_len, ops = pending.pop()
            continue
        if msg_len > MAX_MSG:
            raise Bad("message longer than %d bytes" % MAX_MSG)
        if tag == OP_SHA256:
            new_len = 32
        elif tag in (OP_APPEND, OP_PREPEND):
            operand, pos = varbytes(data, pos, MAX_OPERAND, min_len=1)
            new_len = msg_len + len(operand)
        else:
            raise Bad("unsupported op 0x%02x" % tag)
        if new_len > MAX_OPERAND:
            raise Bad("result longer than %d bytes" % MAX_OPERAND)
        msg_len = new_len
        ops += 1
        if ops > MAX_OPS_ON_A_PATH:
            raise Bad("more than %d operations on one path" % MAX_OPS_ON_A_PATH)
    if pos != len(data):
        raise Bad("trailing bytes after the proof")
    return found


def main():
    if len(sys.argv) != 3:
        print("usage: check-proof.py FILE DIGESTHEX")
        return 2
    try:
        with open(sys.argv[1], "rb") as fd:
            data = fd.read()
        digest = bytes.fromhex(sys.argv[2])
    except (OSError, ValueError) as exc:
        print("unreadable (%s)" % type(exc).__name__)
        return 1
    if len(digest) != 32:
        print("digest is not 32 bytes")
        return 1
    try:
        check(data, digest)
    except Bad as exc:
        print(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
