"""The proof-byte corpus (tests/proof_corpus.py, carried from the
calendar fork's ops/tests/proof_corpus.py) against check-proof.py, and
against the public client where it is importable. Of the three claims a
reader can make, check-proof.py makes the first, "parses", and the corpus
pins it; the library's verdict is computed here, never assumed. A reader
that skipped an attestation's payload by its declared length would pass
an empty bitcoin payload that the public client refuses."""
import importlib.util
import io
import os
import random
import subprocess
import sys
import tempfile
import unittest

import proof_corpus as corpus

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CHECKER = os.path.join(REPO, "check-proof.py")
ORACLE = sys.executable   # the interpreter whose opentimestamps, if any, is the oracle

spec = importlib.util.spec_from_file_location("check_proof", CHECKER)
check_proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_proof)

try:
    from opentimestamps.core.notary import BitcoinBlockHeaderAttestation, PendingAttestation
    from opentimestamps.core.serialize import StreamDeserializationContext
    from opentimestamps.core.timestamp import DetachedTimestampFile
    HAVE_LIBRARY = True
except ImportError:      # the payer host need not have it
    HAVE_LIBRARY = False


def reader_verdict(data):
    try:
        atts = check_proof.check(data, corpus.DIGEST)
    except check_proof.Bad as exc:
        return "invalid", str(exc)
    return "parses", sorted(atts, key=repr)


def library_verdict(data):
    try:
        f = DetachedTimestampFile.deserialize(StreamDeserializationContext(io.BytesIO(data)))
    except Exception as exc:
        return "invalid", type(exc).__name__
    out = []
    for _, att in f.timestamp.all_attestations():
        if isinstance(att, PendingAttestation):
            out.append(("pending", att.uri))
        elif isinstance(att, BitcoinBlockHeaderAttestation):
            out.append(("bitcoin", att.height))
        else:
            out.append(("unknown", att.TAG.hex()))
    return "parses", sorted(out, key=repr)


def cli(data):
    """check-proof.py as pay402 runs it: (exit status, its one line)."""
    with tempfile.NamedTemporaryFile(delete=False) as fd:
        fd.write(data)
    try:
        p = subprocess.run([sys.executable, CHECKER, fd.name, corpus.DIGEST.hex()],
                           capture_output=True, text=True, env={"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1"})
    finally:
        os.unlink(fd.name)
    return p.returncode, p.stdout.strip()


class Test_corpus_against_the_reader(unittest.TestCase):
    def test_every_case(self):
        for name, data, verdict, shape, attestations in corpus.cases():
            with self.subTest(name):
                ours = reader_verdict(data)
                if verdict == "parses":
                    self.assertEqual(ours, ("parses", sorted(attestations, key=repr)))
                else:
                    self.assertEqual(ours[0], "invalid", ours)

    def test_every_prefix_and_extension_is_invalid(self):
        for name, data in list(corpus.prefixes()) + list(corpus.trailing()):
            with self.subTest(name):
                self.assertEqual(reader_verdict(data)[0], "invalid")

    def test_an_empty_bitcoin_payload_and_a_trailing_byte_are_refused_by_the_command(self):
        cases = dict((name, data) for name, data, _, _, _ in corpus.cases())
        for name, reason in (("bitcoin_payload_empty", "truncated varuint"),
                             ("bitcoin_payload_trailing_byte", "trailing bytes in the bitcoin attestation")):
            with self.subTest(name):
                rc, line = cli(cases[name])
                self.assertEqual((rc, line), (1, reason))
        rc, line = cli(cases["bitcoin_linear"])
        self.assertEqual((rc, line), (0, ""))

    def test_the_reader_never_raises_anything_but_its_own_error(self):
        """A reader that lets IndexError or UnicodeDecodeError out turns a
        bad answer into a crash of the run (the fork's F13, F14). Only
        Bad may escape."""
        rng = random.Random(20260918)
        shapes = [data for _, data, verdict, _, _ in corpus.cases() if verdict == "parses"]
        for _ in range(2000):
            data = bytearray(rng.choice(shapes))
            for _ in range(rng.randint(1, 3)):
                pos = rng.randrange(len(data)) if data else 0
                roll = rng.random()
                if roll < 0.5 and data:
                    data[pos] = rng.randrange(256)
                elif roll < 0.8:
                    data.insert(pos, rng.randrange(256))
                elif data:
                    del data[pos]
            try:
                check_proof.check(bytes(data), corpus.DIGEST)
            except check_proof.Bad:
                pass


@unittest.skipUnless(HAVE_LIBRARY, "opentimestamps is not importable by %s: the oracle comparison did not run" % ORACLE)
class Test_corpus_against_the_library(unittest.TestCase):
    """The oracle is the opentimestamps package importable by the
    interpreter running this suite (ORACLE); the suite never depends on
    any other interpreter."""

    def test_parses_and_invalid_agree_with_the_public_client(self):
        for name, data, verdict, shape, attestations in corpus.cases():
            with self.subTest(name):
                lib = library_verdict(data)
                if verdict == "parses":
                    self.assertEqual(lib, ("parses", sorted(attestations, key=repr)))
                elif verdict == "invalid":
                    self.assertEqual(lib[0], "invalid", lib)
                else:
                    self.assertEqual(lib[0], "parses", "a narrowing is something the client reads: " + repr(lib))
                    self.assertEqual(reader_verdict(data)[0], "invalid")

    def test_prefixes_and_extensions_agree(self):
        for name, data in list(corpus.prefixes()) + list(corpus.trailing()):
            with self.subTest(name):
                self.assertEqual(library_verdict(data)[0], "invalid")


if __name__ == "__main__":
    unittest.main()
