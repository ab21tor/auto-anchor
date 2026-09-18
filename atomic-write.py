#!/usr/bin/env python3
"""atomic-write.py DEST < content

Write stdin to DEST by checked write: a temporary file in DEST's
directory, fsynced; renamed over DEST; the directory fsynced. What a
failure leaves depends on where it happens. Before the rename (a full
disk, a permission, a short write): the temporary file is removed and the
old DEST stands. At the directory fsync, after the rename: the new DEST is
visible, its durability is not known, and the old DEST is gone. Either way
one fixed-format line goes to stderr and the exit status is 1; the caller
decides what a failed write means for the file it now sees. The helper
does not promise that the old DEST survives every failure (2026-09-18
gate, ruling 1: the text here used to say so, which the code never did).
Used by pay402 for its purchase record; the standing payer that shared it
was retired.

A checked write is what this establishes; a power cut is not simulated
and no test here claims power-loss durability."""
import os
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        print("usage: atomic-write.py DEST < content", file=sys.stderr)
        return 2
    dest = sys.argv[1]
    directory = os.path.dirname(os.path.abspath(dest)) or "."
    data = sys.stdin.buffer.read()
    fd = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(dest) + ".", dir=directory)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("write made no progress")
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
        tmp = None
        dir_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as exc:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        print("atomic-write: failed (%s)" % type(exc).__name__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
