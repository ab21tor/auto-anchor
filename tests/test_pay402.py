"""Tests for pay402 and its helpers.

A fake gateway (402 challenge, then whatever `redeem` says) and a fake
phoenixd (decode, pay, the outgoing-payment lookup) on loopback; the
script runs as a subprocess with a throwaway HOME and PROOF_DIR. Stdlib
only; nothing here touches a real wallet.

    python3 -m unittest discover -s tests

Two kinds of interruption, kept apart: an injected OSError, raised inside
a `sitecustomize` placed on PYTHONPATH at the directory fsync of a named
file (the script unwinds and says what it left); and process death,
SIGKILL to the script at a boundary (returncode -9, no message). Every
injection writes a line to a log the test reads back, so a case whose
boundary was never reached fails. No power cut is simulated."""
import hashlib
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, "pay402")
HELPERS = ("atomic-write.py", "check-proof.py", "decode-invoice.py", "decode-amount.py")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


PREIMAGES = {}   # payment hash -> preimage, filled by invoice(); the fake wallet's secret


class Phoenixd:
    """decodeinvoice echoes the amount the invoice string claims (and the
    invoice's payment hash); payinvoice hands out the preimage once per
    hash and records every attempt. drop_next makes the next payinvoice
    pay and then drop the connection (the answer lost after the money
    moved); lookup_down makes GET /payments/outgoingbyhash answer 500
    (the wallet not answering); hold_pays blocks every payinvoice until
    the event is set, and pay_entered is set as soon as one arrives (the
    boundary the lock and the death tests wait for). The lookup answers
    as phoenixd 0.8.0 does: the best record for the hash, or 204."""

    def __init__(self):
        self.lock = threading.Lock()
        self.pays = []
        self.decodes = []
        self.paid = set()
        self.lookups = []
        self.drop_next = 0
        self.lookup_down = False
        self.hold_pays = None
        self.pay_entered = threading.Event()
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _send(self, status, obj):
                body = json.dumps(obj).encode() if obj is not None else b""
                self.send_response(status)
                if obj is not None:
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if body:
                    self.wfile.write(body)

            def do_GET(self):
                path = urlparse(self.path).path
                prefix = "/payments/outgoingbyhash/"
                if path.startswith(prefix):
                    h = path[len(prefix):]
                    with outer.lock:
                        outer.lookups.append(h)
                        if outer.lookup_down:
                            self._send(500, {"reason": "injected lookup failure"})
                        elif h in outer.paid:
                            self._send(200, {"paymentHash": h, "preimage": PREIMAGES[h], "isPaid": True,
                                             "completedAt": 1, "sent": 1})
                        else:
                            self._send(204, None)
                    return
                self._send(404, {"reason": "no such path"})

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                form = {k: v[0] for k, v in parse_qs(self.rfile.read(n).decode()).items()}
                inv = form.get("invoice", "")
                rest = inv[len("lnfake1"):]
                h, amount = rest[:64], rest[65:]          # lnfake1<64 hex>a<sats>
                path = urlparse(self.path).path
                if path == "/payinvoice":
                    outer.pay_entered.set()
                    if outer.hold_pays is not None:
                        outer.hold_pays.wait(30)
                with outer.lock:
                    if path == "/decodeinvoice":
                        outer.decodes.append(h)
                        if not inv.startswith("lnfake1") or rest[64:65] != "a" or not amount.isdigit():
                            self._send(400, {"reason": "invalid invoice"})
                            return
                        self._send(200, {"amountSat": int(amount), "paymentHash": h})
                        return
                    if path == "/payinvoice":
                        if h in outer.paid:
                            outer.pays.append((h, int(amount), "refused_already_paid"))
                            self._send(400, {"reason": "invoice already paid"})
                            return
                        outer.paid.add(h)
                        if outer.drop_next > 0:
                            outer.drop_next -= 1
                            outer.pays.append((h, int(amount), "paid_answer_lost"))
                            self.close_connection = True
                            self.wfile.close()
                            return
                        outer.pays.append((h, int(amount), "paid"))
                        self._send(200, {"paymentPreimage": PREIMAGES[h], "paymentHash": h})
                        return
                    self._send(404, {"reason": "no such path"})

        self.port = free_port()
        self.srv = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def paid_attempts(self):
        with self.lock:
            return [p for p in self.pays if p[2].startswith("paid")]

    def stop(self):
        self.srv.shutdown()


def invoice(amount, h=None):
    if h is None:
        preimage = secrets.token_hex(32)
        h = hashlib.sha256(bytes.fromhex(preimage)).hexdigest()
        PREIMAGES[h] = preimage
    return h, "lnfake1%sa%s" % (h, amount)


PROOF_MAGIC = b'\x00OpenTimestamps\x00\x00Proof\x00\xbf\x89\xe2\xe8\x84\xe8\x92\x94'
MACAROON = "bWFj"   # what every challenge below carries


def pending_proof(digest_hex):
    uri = b"http://127.0.0.1:14788"
    payload = bytes([len(uri)]) + uri
    return PROOF_MAGIC + b"\x01\x08" + bytes.fromhex(digest_hex) + b"\x00" + bytes.fromhex("83dfe30d2ef90c8e") + bytes([len(payload)]) + payload


class Pay402Gateway:
    """A gateway: 402 with an L402 challenge for an unauthenticated
    /timestamp (the one invoice string, or with fresh_invoices a new one
    per challenge), and for an authenticated one whatever `redeem` says:
    ("proof",) a real pending proof, ("garbage",) bytes that are not a
    proof, ("status", 503) an error. hold_redeems blocks every redeem
    until the event is set; redeem_entered is set when one arrives."""

    def __init__(self, invoice_string, fresh_invoices=False):
        self.invoice_string = invoice_string
        self.fresh_invoices = fresh_invoices
        self.redeem = ("proof",)
        self.redeems = []
        self.challenges = []
        self.hold_redeems = None
        self.redeem_entered = threading.Event()
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n).decode() or "{}")
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("L402 "):
                    inv = invoice(21)[1] if outer.fresh_invoices else outer.invoice_string
                    outer.challenges.append(inv)
                    self.send_response(402)
                    self.send_header("WWW-Authenticate", 'L402 macaroon="%s", invoice="%s"' % (MACAROON, inv))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                outer.redeem_entered.set()
                if outer.hold_redeems is not None:
                    outer.hold_redeems.wait(30)
                outer.redeems.append(auth)
                kind = outer.redeem[0]
                if kind == "proof":
                    data, status = pending_proof(body["digest"]), 200
                elif kind == "garbage":
                    data, status = b"not an OTS proof", 200
                else:
                    data, status = b'{"detail":"paused"}', outer.redeem[1]
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.port = free_port()
        self.srv = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def stop(self):
        self.srv.shutdown()


# The injection: os.fsync logs every call ("fsync dir|file <argv[-1]>")
# and, for a directory fsync whose invoking argv ends with FAIL_TARGET,
# either raises OSError (FAIL_MODE=oserror: the script unwinds) or
# SIGKILLs the script, its parent (FAIL_MODE=kill: process death). Both
# write an "injected" line first, so a test can assert the boundary was
# reached. Unset FAIL_MODE: logging only.
SITECUSTOMIZE = '''import os, signal, stat, sys
_real_fsync = os.fsync


def _log(line):
    with open(os.environ["FAULT_LOG"], "a") as f:
        f.write(line + "\\n")


def fsync(fd):
    kind = "dir" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file"
    target = sys.argv[-1] if sys.argv else ""
    _log("fsync %s %s" % (kind, target))
    mode = os.environ.get("FAIL_MODE", "")
    if kind == "dir" and mode and target == os.environ.get("FAIL_TARGET", ""):
        _log("injected %s %s" % (mode, target))
        if mode == "kill":
            os.kill(os.getppid(), signal.SIGKILL)
            os._exit(0)
        raise OSError(5, "injected I/O error")
    return _real_fsync(fd)


os.fsync = fsync
'''


class Pay402Case(unittest.TestCase):
    """A fresh fake wallet, fake gateway, HOME and PROOF_DIR per test."""

    fresh_invoices = False

    def setUp(self):
        self.phoenixd = Phoenixd()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.phoenixd.stop)
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(os.path.join(self.home, ".phoenix"))
        with open(os.path.join(self.home, ".phoenix", "phoenix.conf"), "w") as fd:
            fd.write("http-password=test-password\n")
        self.h, self.inv = invoice(21)
        self.gateway = Pay402Gateway(self.inv, fresh_invoices=self.fresh_invoices)
        self.addCleanup(self.gateway.stop)
        self.proofs = os.path.join(self.tmp.name, "proofs")
        self.digest = "ab" * 32
        self.out = os.path.join(self.proofs, self.digest + ".ots")
        self.sidecar = os.path.join(self.proofs, self.digest + ".l402")
        self.lockfile = os.path.join(self.proofs, self.digest + ".lock")
        self.script = SCRIPT
        self.injection = os.path.join(self.tmp.name, "injection")
        os.mkdir(self.injection)
        with open(os.path.join(self.injection, "sitecustomize.py"), "w") as fd:
            fd.write(SITECUSTOMIZE)
        self.fault_log = os.path.join(self.tmp.name, "fault.log")
        open(self.fault_log, "w").close()

    def env(self, mode=None, **extra):
        env = {"PATH": os.environ["PATH"], "HOME": self.home, "LANG": "C",
               "PYTHONDONTWRITEBYTECODE": "1",
               "GATEWAY_URL": "http://127.0.0.1:%d" % self.gateway.port,
               "PHOENIXD_URL": "http://127.0.0.1:%d" % self.phoenixd.port, "PROOF_DIR": self.proofs}
        if mode is not None:
            env.update({"PYTHONPATH": self.injection, "FAULT_LOG": self.fault_log,
                        "FAIL_TARGET": self.out, "FAIL_MODE": mode})
        env.update(extra)
        return env

    def run_pay402(self, mode=None, **extra):
        p = subprocess.run(["/bin/bash", self.script, self.digest], env=self.env(mode, **extra),
                           capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout + p.stderr

    def start_pay402(self, mode=None, **extra):
        return subprocess.Popen(["/bin/bash", self.script, self.digest], env=self.env(mode, **extra),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def fault_lines(self):
        with open(self.fault_log) as fd:
            return fd.read().splitlines()

    def sidecar_json(self):
        with open(self.sidecar) as fd:
            return json.load(fd)

    def proof_bytes(self):
        with open(self.out, "rb") as fd:
            return fd.read()


class Test_pay402(Pay402Case):
    def test_a_purchase_lands_a_checked_proof_and_clears_its_sidecar(self):
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        self.assertFalse(os.path.exists(self.sidecar))
        self.assertEqual(sorted(os.listdir(self.proofs)), sorted([self.digest + ".ots", self.digest + ".lock"]))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)

    def test_garbage_is_never_written_as_a_proof(self):
        self.gateway.redeem = ("garbage",)
        rc, out = self.run_pay402()
        self.assertEqual(rc, 7, out)
        self.assertIn("not a proof of this digest", out)
        self.assertFalse(os.path.exists(self.out))
        # The paid preimage is on file: a rerun redeems without paying again.
        self.assertTrue(os.path.exists(self.sidecar))
        self.assertEqual(sorted(os.listdir(self.proofs)), sorted([self.digest + ".l402", self.digest + ".lock"]))
        self.gateway.redeem = ("proof",)
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("resuming: preimage on file", out)
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))

    def test_a_failed_redeem_never_overwrites_an_existing_proof(self):
        os.makedirs(self.proofs)
        with open(self.out, "wb") as fd:
            fd.write(b"prior proof bytes, not valid, to be left alone")
        self.gateway.redeem = ("status", 503)
        rc, out = self.run_pay402()
        self.assertEqual(rc, 7, out)
        self.assertIn("redeem failed (HTTP 503)", out)
        self.assertEqual(self.proof_bytes(), b"prior proof bytes, not valid, to be left alone")

    def test_an_existing_valid_proof_skips_the_purchase(self):
        os.makedirs(self.proofs)
        with open(self.out, "wb") as fd:
            fd.write(pending_proof(self.digest))
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("already have a valid proof", out)
        self.assertEqual(self.phoenixd.pays, [])
        self.assertEqual(self.gateway.redeems, [])

    def test_the_invoice_is_on_file_before_paying_and_a_lost_answer_is_reconciled(self):
        self.phoenixd.drop_next = 1
        self.phoenixd.lookup_down = True
        rc, out = self.run_pay402()
        self.assertEqual(rc, 6, out)
        self.assertIn("not paying again", out)
        sidecar = self.sidecar_json()
        self.assertEqual((sidecar["invoice"], sidecar["payment_hash"], sidecar["amount_sats"]), (self.inv, self.h, 21))
        self.assertNotIn("preimage", sidecar)
        # Rerun with the wallet answering: the preimage is fetched from the
        # wallet, nothing is paid again, the proof lands.
        self.phoenixd.lookup_down = False
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("the wallet holds the preimage", out)
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))


class Test_completion_boundary(Pay402Case):
    """2026-09-18 gate, ruling 1: a visible proof is not a completed
    purchase; the sidecar owns the work until the proof's bytes and its
    directory entry are synced, on the recovery rerun too. The gate's
    probe reproduced the defect: an injected directory-fsync failure, then
    a rerun that deleted the sidecar on sight with no fsync at all."""

    def test_an_injected_fsync_failure_after_the_rename_is_re_established_by_the_rerun(self):
        # Run 1: the directory fsync after the rename raises. The script
        # unwinds: exit 7, the proof visible, the sidecar standing, and it
        # says the proof is not known durable.
        rc, out = self.run_pay402("oserror")
        self.assertEqual(rc, 7, out)
        self.assertIn("not known durable", out)
        self.assertTrue(os.path.exists(self.out), "the rename happened: the proof is visible")
        self.assertTrue(os.path.exists(self.sidecar), "the sidecar still owns the purchase")
        self.assertEqual(self.fault_lines().count("injected oserror " + self.out), 1, self.fault_lines())
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        # Run 2, the recovery interrupted again: the same injection fires at
        # the rerun's own sync of the visible proof; the sidecar is kept.
        rc, out = self.run_pay402("oserror")
        self.assertEqual(rc, 7, out)
        self.assertIn("could not be synced", out)
        self.assertTrue(os.path.exists(self.sidecar))
        self.assertEqual(self.fault_lines().count("injected oserror " + self.out), 2)
        self.assertEqual(len(self.gateway.redeems), 1, "no second redeem: the proof was already visible")
        # Run 3, clean: the rerun fsyncs the file and its directory, then
        # removes the sidecar. Convergence: one payment, one redeem.
        before = len(self.fault_lines())
        rc, out = self.run_pay402("")
        self.assertEqual(rc, 0, out)
        self.assertIn("already have a valid proof", out)
        self.assertFalse(os.path.exists(self.sidecar))
        rerun = self.fault_lines()[before:]
        self.assertIn("fsync file " + self.out, rerun)
        self.assertIn("fsync dir " + self.out, rerun)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        self.assertEqual(len(self.gateway.redeems), 1)
        # Run 4: nothing left to do.
        rc, out = self.run_pay402("")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(self.sidecar))

    def test_death_at_the_directory_fsync_after_the_rename_is_re_established_by_the_rerun(self):
        # Run 1: the script is killed at the directory fsync. No message,
        # returncode -9, the proof visible, the sidecar standing.
        rc, out = self.run_pay402("kill")
        self.assertEqual(rc, -9, out)
        self.assertNotIn("pay402:", out)
        self.assertTrue(os.path.exists(self.out))
        self.assertTrue(os.path.exists(self.sidecar))
        self.assertEqual(self.fault_lines().count("injected kill " + self.out), 1, self.fault_lines())
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        # Run 2: killed again, at the rerun's own sync; the sidecar is kept.
        rc, out = self.run_pay402("kill")
        self.assertEqual(rc, -9, out)
        self.assertNotIn("pay402:", out)
        self.assertTrue(os.path.exists(self.sidecar))
        self.assertEqual(self.fault_lines().count("injected kill " + self.out), 2)
        # Run 3, clean: converges with the file and directory synced.
        before = len(self.fault_lines())
        rc, out = self.run_pay402("")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(self.sidecar))
        rerun = self.fault_lines()[before:]
        self.assertIn("fsync dir " + self.out, rerun)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        self.assertEqual(len(self.gateway.redeems), 1)


class Test_lock(Pay402Case):
    """2026-09-15/16 review F05: two pay402 processes for one digest bought
    it twice. One process per digest: the second exits 9 at once."""

    fresh_invoices = True   # the review's shape: each challenge is a new invoice

    def test_a_second_process_for_the_same_digest_is_refused_at_once(self):
        self.phoenixd.hold_pays = threading.Event()
        a = self.start_pay402()
        self.assertTrue(self.phoenixd.pay_entered.wait(20), "the boundary: A never reached the wallet")
        b = self.start_pay402()
        try:
            out_b, _ = b.communicate(timeout=5)
            b_finished_while_a_paid = True
        except subprocess.TimeoutExpired:
            b_finished_while_a_paid = False
        self.phoenixd.hold_pays.set()
        if not b_finished_while_a_paid:
            out_b, _ = b.communicate(timeout=60)
        out_a, _ = a.communicate(timeout=60)
        self.assertTrue(b_finished_while_a_paid, "B did not exit while A held the lock: " + out_b)
        self.assertEqual(b.returncode, 9, out_b)
        self.assertIn("another pay402 holds the lock for this digest", out_b)
        self.assertEqual(a.returncode, 0, out_a)
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1, self.phoenixd.pays)
        self.assertEqual(len(self.gateway.challenges), 1, "B never took a challenge")
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        self.assertEqual(len(self.gateway.redeems), 1)
        self.assertFalse(os.path.exists(self.sidecar))
        # A third run afterwards finds the proof; the lock file stays.
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("already have a valid proof", out)
        self.assertTrue(os.path.exists(self.lockfile))


class Test_argv(Pay402Case):
    """2026-09-18 gate, ruling 8: the wallet password never reaches argv
    (curl stdin config), and neither may the macaroon or the preimage:
    both are readable in the process list for the life of a call."""

    def test_the_macaroon_the_preimage_and_the_password_never_reach_argv(self):
        wrappers = os.path.join(self.tmp.name, "bin")
        os.mkdir(wrappers)
        argv_log = os.path.join(self.tmp.name, "argv.log")
        wrapper = os.path.join(wrappers, "python3")
        with open(wrapper, "w") as fd:
            fd.write('#!/bin/bash\nprintf \'%%s\\n\' "$@" >> "$ARGV_LOG"\nexec "%s" "$@"\n' % sys.executable)
        os.chmod(wrapper, 0o755)
        rc, out = self.run_pay402(PATH=wrappers + os.pathsep + os.environ["PATH"], ARGV_LOG=argv_log)
        self.assertEqual(rc, 0, out)
        with open(argv_log) as fd:
            logged = fd.read()
        self.assertIn("check-proof.py", logged, "the wrapper was used")
        self.assertNotIn(MACAROON, logged)
        self.assertNotIn(PREIMAGES[self.h], logged)
        self.assertNotIn("test-password", logged)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        # The sidecar was written with the right fields on the way: replay
        # its resume path to see the preimage reached it.
        self.gateway.redeem = ("garbage",)
        os.unlink(self.out)
        rc, out = self.run_pay402(PATH=wrappers + os.pathsep + os.environ["PATH"], ARGV_LOG=argv_log)
        self.assertEqual(rc, 7, out)
        sidecar = self.sidecar_json()
        self.assertEqual((sidecar["macaroon"], sidecar["invoice"], sidecar["payment_hash"], sidecar["amount_sats"]),
                         (MACAROON, self.inv, self.h, 21))
        self.assertEqual(sidecar["preimage"], PREIMAGES[self.h])
        with open(argv_log) as fd:
            logged = fd.read()
        self.assertNotIn(MACAROON, logged)
        self.assertNotIn(PREIMAGES[self.h], logged)
        self.assertNotIn("test-password", logged)


class Test_interruptions(Pay402Case):
    """Process death at the two remaining boundaries of a purchase: while
    the wallet holds the payment (the sidecar has the invoice and no
    preimage) and while the gateway holds the redeem (the sidecar has the
    preimage). Each rerun is interrupted again, then converges. These pin
    the behaviour the script already had."""

    def wait_for(self, predicate, what):
        deadline = time.time() + 20
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("never reached: " + what)

    def test_death_while_the_wallet_holds_the_payment(self):
        self.phoenixd.hold_pays = threading.Event()
        p = self.start_pay402()
        self.assertTrue(self.phoenixd.pay_entered.wait(20), "the boundary: the wallet call was never entered")
        p.kill()
        self.phoenixd.hold_pays.set()   # the wallet completes a payment the dead script never heard of
        out, _ = p.communicate(timeout=60)
        self.assertEqual(p.returncode, -9, out)
        self.assertNotIn("pay402:", out)
        sidecar = self.sidecar_json()
        self.assertEqual(sidecar["payment_hash"], self.h)
        self.assertNotIn("preimage", sidecar)
        self.assertFalse(os.path.exists(self.out))
        self.wait_for(lambda: len(self.phoenixd.paid_attempts()) == 1, "the wallet's record of the payment")
        # The rerun asks the wallet, learns the preimage, and is killed at
        # the redeem: the sidecar now holds the preimage.
        self.gateway.hold_redeems = threading.Event()
        p2 = self.start_pay402()
        self.assertTrue(self.gateway.redeem_entered.wait(20), "the boundary: the redeem was never entered")
        p2.kill()
        self.gateway.hold_redeems.set()
        out, _ = p2.communicate(timeout=60)
        self.assertEqual(p2.returncode, -9, out)
        self.assertEqual(self.sidecar_json()["preimage"], PREIMAGES[self.h])
        self.assertFalse(os.path.exists(self.out))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        # The third run redeems from the preimage on file; the fourth finds
        # the proof.
        self.gateway.hold_redeems = None
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("resuming: preimage on file", out)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        self.assertFalse(os.path.exists(self.sidecar))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("already have a valid proof", out)

    def test_death_while_the_gateway_holds_the_redeem(self):
        self.gateway.hold_redeems = threading.Event()
        p = self.start_pay402()
        self.assertTrue(self.gateway.redeem_entered.wait(20), "the boundary: the redeem was never entered")
        p.kill()
        self.gateway.hold_redeems.set()
        out, _ = p.communicate(timeout=60)
        self.assertEqual(p.returncode, -9, out)
        self.assertNotIn("pay402:", out)
        self.assertEqual(self.sidecar_json()["preimage"], PREIMAGES[self.h])
        self.assertFalse(os.path.exists(self.out))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        # Interrupted again at the same boundary, then converges.
        self.gateway.redeem_entered.clear()
        p2 = self.start_pay402()
        self.assertTrue(self.gateway.redeem_entered.wait(20))
        p2.kill()
        out, _ = p2.communicate(timeout=60)
        self.assertEqual(p2.returncode, -9, out)
        self.assertEqual(self.sidecar_json()["preimage"], PREIMAGES[self.h])
        self.gateway.hold_redeems = None
        rc, out = self.run_pay402()
        self.assertEqual(rc, 0, out)
        self.assertIn("resuming: preimage on file", out)
        self.assertEqual(self.proof_bytes(), pending_proof(self.digest))
        self.assertFalse(os.path.exists(self.sidecar))
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        self.assertEqual(len(self.phoenixd.lookups), 0, "a preimage on file is never looked up")


class Test_atomic_write(unittest.TestCase):
    """The checked write, at its two failure points. Relocated from the
    retired standing payer's tests and narrowed to what each case
    exercises (2026-09-18 gate, ruling 1)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.helper = os.path.join(REPO, "atomic-write.py")
        self.dest = os.path.join(self.tmp.name, "target")
        with open(self.dest, "w") as fd:
            fd.write("old\n")

    def test_a_failure_before_the_rename_leaves_the_old_destination(self):
        p = subprocess.run([sys.executable, self.helper, self.dest], input="new\n", text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(self.dest) as fd:
            self.assertEqual(fd.read(), "new\n")
        os.chmod(self.tmp.name, 0o500)   # the temporary file cannot be made
        self.addCleanup(os.chmod, self.tmp.name, 0o700)
        p = subprocess.run([sys.executable, self.helper, self.dest], input="newer\n", text=True, capture_output=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("atomic-write: failed", p.stderr)
        with open(self.dest) as fd:
            self.assertEqual(fd.read(), "new\n")
        os.chmod(self.tmp.name, 0o700)
        self.assertEqual([n for n in os.listdir(self.tmp.name) if n.startswith("target.")], [])

    def test_a_failure_at_the_directory_fsync_after_the_rename_leaves_the_new_destination_visible(self):
        # A pin of what the code does, not a change: the new bytes are in
        # place and their durability is uncertain; exit 1 says so.
        injection = os.path.join(self.tmp.name, "injection")
        os.mkdir(injection)
        with open(os.path.join(injection, "sitecustomize.py"), "w") as fd:
            fd.write(SITECUSTOMIZE)
        log = os.path.join(self.tmp.name, "fault.log")
        env = dict(os.environ, PYTHONPATH=injection, PYTHONDONTWRITEBYTECODE="1",
                   FAULT_LOG=log, FAIL_TARGET=self.dest, FAIL_MODE="oserror")
        p = subprocess.run([sys.executable, self.helper, self.dest], input="new\n", text=True,
                           capture_output=True, env=env)
        self.assertEqual(p.returncode, 1)
        self.assertIn("atomic-write: failed", p.stderr)
        with open(log) as fd:
            self.assertIn("injected oserror " + self.dest, fd.read())
        with open(self.dest) as fd:
            self.assertEqual(fd.read(), "new\n", "the rename happened before the failure")
        self.assertEqual([n for n in os.listdir(self.tmp.name) if n.startswith("target.")], [])


if __name__ == "__main__":
    unittest.main()
