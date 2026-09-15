#!/usr/bin/env python3
"""atomic-write.py DEST < content

Write stdin to DEST atomically and durably, or fail without touching DEST:
a temporary file in DEST's directory, fsynced; renamed over DEST; the
directory fsynced. Any failure (a full disk, a permission, a short write)
removes the temporary file, leaves the last valid DEST in place, prints one
fixed-format line to stderr and exits 1. Shared by pay-anchor-bills.sh
(its state file) and pay402 (its sidecar).

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
