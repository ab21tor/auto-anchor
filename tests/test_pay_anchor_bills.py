"""Unit tests for pay-anchor-bills.sh.

A fake gateway serves crafted /anchor-bills responses, a fake phoenixd
decodes and pays (in "echo" mode: the invoice string says what the bill
claims, the worst case), and the script runs with a throwaway HOME and
state file. The tests read what it printed, what it asked phoenixd to pay,
and what it wrote to the state file. Stdlib only; no network beyond
loopback; nothing here touches a real wallet.

    python3 -m unittest discover -s tests

PAYER_SCRIPT=/path/to/another/pay-anchor-bills.sh runs the same tests
against that copy (how the fixes were shown red before they were made).
"""
import base64
import json
import os
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("PAYER_SCRIPT") or os.path.join(os.path.dirname(HERE), "pay-anchor-bills.sh")
RATE = 3
TODAY = time.strftime("%Y-%m-%d", time.gmtime())


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Gateway:
    """Serves the queued response documents; the payer's unauthenticated
    reachability probe gets a 401 and consumes nothing, like the real one."""

    def __init__(self):
        self.queue = []
        self.lock = threading.Lock()
        self.fetches = 0
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_GET(self):
                with outer.lock:
                    if not self.headers.get("Authorization"):
                        body = b'{"detail":"Invalid or missing bearer token"}'
                        status = 401
                    else:
                        outer.fetches += 1
                        doc = outer.queue.pop(0) if len(outer.queue) > 1 else outer.queue[0]
                        body = json.dumps(doc).encode()
                        status = 200
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.port = free_port()
        self.srv = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def serve(self, *docs):
        with self.lock:
            self.queue = list(docs)

    def stop(self):
        self.srv.shutdown()


class Phoenixd:
    """decodeinvoice echoes the amount the invoice string claims; payinvoice
    hands out a preimage once per hash, records every attempt, and can be
    told to fail the next call."""

    def __init__(self):
        self.lock = threading.Lock()
        self.pays = []
        self.decodes = []
        self.paid = set()
        self.fail_next = 0
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _send(self, status, obj):
                body = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                form = {k: v[0] for k, v in parse_qs(self.rfile.read(n).decode()).items()}
                inv = form.get("invoice", "")
                rest = inv[len("lnfake1"):]
                h, amount = rest[:64], rest[65:]          # lnfake1<64 hex>a<sats>
                path = urlparse(self.path).path
                with outer.lock:
                    if path == "/decodeinvoice":
                        outer.decodes.append(h)
                        if not inv.startswith("lnfake1") or rest[64:65] != "a" or not amount.isdigit():
                            self._send(400, {"reason": "invalid invoice"})
                            return
                        self._send(200, {"amountSat": int(amount), "paymentHash": h})
                        return
                    if path == "/payinvoice":
                        if outer.fail_next > 0:
                            outer.fail_next -= 1
                            outer.pays.append((h, int(amount) if amount.isdigit() else None, "failed"))
                            self._send(500, {"reason": "injected failure"})
                            return
                        if h in outer.paid:
                            outer.pays.append((h, int(amount), "refused_already_paid"))
                            self._send(400, {"reason": "invoice already paid"})
                            return
                        outer.paid.add(h)
                        outer.pays.append((h, int(amount), "paid"))
                        self._send(200, {"paymentPreimage": secrets.token_hex(32), "paymentHash": h})
                        return
                    self._send(404, {"reason": "no such path"})

        self.port = free_port()
        self.srv = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def paid_attempts(self):
        with self.lock:
            return [p for p in self.pays if p[2] == "paid"]

    def stop(self):
        self.srv.shutdown()


def invoice(amount, h=None):
    h = h or secrets.token_hex(32)
    return h, "lnfake1%sa%s" % (h, amount)


def bill(txid, records, amount, h, bolt11, status="unpaid"):
    return {"txid": txid, "fee_sats": 100, "commitments": 1, "confirmed_height": 10,
            "confirmed_at": int(time.time()) - 60, "records": records, "amount_sats": amount,
            "status": status, "payment_hash": h, "bolt11": bolt11, "invoice_created_at": int(time.time())}


def doc(*bills):
    unpaid = [b for b in bills if b["status"] == "unpaid"]
    return {"bills": list(bills), "summary": {"unpaid_count": len(unpaid),
                                              "unpaid_sats": sum(b["amount_sats"] for b in unpaid)}}


class PayerCase(unittest.TestCase):
    def setUp(self):
        self.gateway = Gateway()
        self.phoenixd = Phoenixd()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.gateway.stop)
        self.addCleanup(self.phoenixd.stop)
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(os.path.join(self.home, ".phoenix"))
        with open(os.path.join(self.home, ".phoenix", "phoenix.conf"), "w") as fd:
            fd.write("http-password=test-password\n")
        self.state = os.path.join(self.tmp.name, "pay-anchor-bills.state")

    def run_payer(self, dry_run=False, audit=RATE, max_bill=10_000_000, budget=10_000_000, **extra):
        env = {"PATH": os.environ["PATH"], "HOME": self.home, "LANG": "C", "TZ": "UTC",
               "BILLS_URL": "http://127.0.0.1:%d/anchor-bills" % self.gateway.port,
               "ANCHOR_BILLS_TOKEN": "test-token", "PHOENIXD_URL": "http://127.0.0.1:%d" % self.phoenixd.port,
               "MAX_SATS_PER_BILL": str(max_bill), "DAILY_BUDGET_SATS": str(budget),
               "DRY_RUN": "true" if dry_run else "false", "STATE_FILE": self.state}
        if audit is not None:
            env["AUDIT_PER_RECORD_SATS"] = str(audit)
        env.update(extra)
        p = subprocess.run(["/bin/bash", SCRIPT], env=env, capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout + p.stderr

    def state_lines(self):
        if not os.path.exists(self.state):
            return None
        with open(self.state) as fd:
            return fd.read().splitlines()

    def reason(self, out, txid):
        for line in out.splitlines():
            if line.startswith("bill %s: " % txid):
                return line[len("bill %s: " % txid):]
        return None


class Test_paying(PayerCase):
    def test_correct_bill_is_paid_and_enters_the_ledger(self):
        h, inv = invoice(30)
        txid = secrets.token_hex(32)
        self.gateway.serve(doc(bill(txid, 10, 30, h, inv)))
        rc, out = self.run_payer()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.reason(out, txid), "paid 30 sat")
        self.assertIn("state: complete", out)
        self.assertEqual([p[:2] for p in self.phoenixd.paid_attempts()], [(h, 30)])
        lines = self.state_lines()
        self.assertEqual(lines[0], "%s 30" % TODAY)
        self.assertEqual(len(lines), 2)
        kind, ltxid, sats, when = lines[1].split(" ")
        self.assertEqual((kind, ltxid, sats), ("paid", txid, "30"))
        self.assertRegex(when, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_dry_run_pays_nothing_and_writes_nothing(self):
        h, inv = invoice(30)
        self.gateway.serve(doc(bill(secrets.token_hex(32), 10, 30, h, inv)))
        rc, out = self.run_payer(dry_run=True)
        self.assertEqual(rc, 0, out)
        self.assertIn("would_pay 30 sat", out)
        self.assertEqual(self.phoenixd.pays, [])
        self.assertIsNone(self.state_lines())

    def test_budget_and_ledger_carry_across_runs(self):
        h1, inv1 = invoice(30)
        h2, inv2 = invoice(40)
        t1, t2 = secrets.token_hex(32), secrets.token_hex(32)
        self.gateway.serve(doc(bill(t1, 10, 30, h1, inv1)))
        self.run_payer()
        self.gateway.serve(doc(bill(t1, 10, 30, h1, inv1, status="paid"), bill(t2, 10, 30 + 10, h2, inv2)))
        rc, out = self.run_payer(audit=None)
        self.assertEqual(self.reason(out, t2), "paid 40 sat")
        self.assertIn("spent_today_sats: 30", out)
        lines = self.state_lines()
        self.assertEqual(lines[0], "%s 70" % TODAY)
        self.assertEqual([l.split(" ")[1] for l in lines[1:]], [t1, t2])


class Test_replay(PayerCase):
    def test_an_anchor_paid_before_is_never_paid_again(self):
        # Run 1 pays the anchor. Run 2 serves the same txid unpaid with a
        # fresh invoice (a gateway defect, or a restored gateway ledger):
        # refused loudly, no phoenixd contact, the ledger untouched.
        h1, inv1 = invoice(30)
        txid = secrets.token_hex(32)
        self.gateway.serve(doc(bill(txid, 10, 30, h1, inv1)))
        rc, out = self.run_payer()
        self.assertEqual(self.reason(out, txid), "paid 30 sat")
        h2, inv2 = invoice(30)
        self.gateway.serve(doc(bill(txid, 10, 30, h2, inv2)))
        rc, out = self.run_payer()
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.reason(out, txid).startswith("skipped reason: already_paid_txid"), out)
        self.assertIn("replay_skipped_count: 1", out)
        self.assertIn("state: needs_attention", out)
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        self.assertNotIn(h2, self.phoenixd.decodes)
        self.assertEqual(len(self.state_lines()), 2)

    def test_one_anchor_two_invoices_one_payment(self):
        h1, inv1 = invoice(30)
        h2, inv2 = invoice(30)
        txid = secrets.token_hex(32)
        self.gateway.serve(doc(bill(txid, 10, 30, h1, inv1), bill(txid, 10, 30, h2, inv2)))
        rc, out = self.run_payer()
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)
        # The second invoice for the anchor just paid is refused by the
        # ledger check (already_paid_txid), which runs first and says why.
        self.assertIn("already_paid_txid", out)
        self.assertIn("replay_skipped_count: 1", out)

    def test_same_invoice_twice_in_one_run_pays_once(self):
        h, inv = invoice(30)
        self.gateway.serve(doc(bill(secrets.token_hex(32), 10, 30, h, inv), bill(secrets.token_hex(32), 10, 30, h, inv)))
        rc, out = self.run_payer()
        self.assertEqual(len(self.phoenixd.paid_attempts()), 1)


class Test_audit(PayerCase):
    def test_wrong_sum_refused_before_any_phoenixd_contact(self):
        h, inv = invoice(31)
        txid = secrets.token_hex(32)
        self.gateway.serve(doc(bill(txid, 10, 31, h, inv)))
        rc, out = self.run_payer()
        self.assertTrue(self.reason(out, txid).startswith("skipped reason: rate_mismatch"), out)
        self.assertIn("records=10*rate=3=30,bill=31", out)
        self.assertEqual(self.phoenixd.decodes, [])
        self.assertIn("state: needs_attention", out)

    def test_absurd_bills_are_refused_loudly_whatever_the_decoder_says(self):
        # The invoice string echoes the claim, so only the payer's own
        # arithmetic stands between these and a payment.
        cases = [("2pow63", 2 ** 63, 2 ** 63), ("1e30", 10 ** 30, 10 ** 30),
                 ("2pow64wrap", 2 ** 64 + 100, 300), ("over_supply", 700_000_000_000_001, 2_100_000_000_000_003)]
        for name, records, amount in cases:
            with self.subTest(name):
                h, inv = invoice(amount)
                txid = secrets.token_hex(32)
                self.gateway.serve(doc(bill(txid, records, amount, h, inv)))
                rc, out = self.run_payer()
                self.assertEqual(rc, 0, out)
                reason = self.reason(out, txid) or ""
                self.assertTrue(reason.startswith("skipped reason: implausible") or reason.startswith("skipped reason: rate_mismatch"), out)
                self.assertIn("state: needs_attention", out)
                self.assertEqual(self.phoenixd.pays, [])
        self.assertIsNone(self.state_lines())

    def test_plausibility_bound_is_configurable(self):
        h, inv = invoice(30)
        txid = secrets.token_hex(32)
        self.gateway.serve(doc(bill(txid, 10, 30, h, inv)))
        rc, out = self.run_payer(MAX_RECORDS_PER_BILL="9")
        self.assertIn("skipped reason: implausible (records=10>max_records_per_bill=9)", out)
        self.assertEqual(self.phoenixd.pays, [])

    def test_oversized_knobs_are_refused_before_any_fetch(self):
        rc, out = self.run_payer(max_bill=10 ** 20)
        self.assertEqual(rc, 2)
        self.assertIn("exceeds 16 digits", out)
        self.assertEqual(self.gateway.fetches, 0)


class Test_state_file(PayerCase):
    def test_future_dated_day_line_stops_the_run(self):
        with open(self.state, "w") as fd:
            fd.write("2099-01-01 5\n")
        h, inv = invoice(30)
        self.gateway.serve(doc(bill(secrets.token_hex(32), 10, 30, h, inv)))
        rc, out = self.run_payer()
        self.assertEqual(rc, 2)
        self.assertIn("state file dated in the future", out)
        self.assertEqual(self.gateway.fetches, 0)
        self.assertEqual(self.phoenixd.pays, [])

    def test_corrupt_ledger_line_stops_the_run(self):
        with open(self.state, "w") as fd:
            fd.write("%s 0\nbogus line here\n" % TODAY)
        h, inv = invoice(30)
        self.gateway.serve(doc(bill(secrets.token_hex(32), 10, 30, h, inv)))
        rc, out = self.run_payer()
        self.assertEqual(rc, 2)
        self.assertIn("state file unreadable", out)
        self.assertEqual(self.gateway.fetches, 0)

    def test_failed_payment_stays_out_of_the_ledger_and_is_retried(self):
        h, inv = invoice(30)
        txid = secrets.token_hex(32)
        self.gateway.serve(doc(bill(txid, 10, 30, h, inv)))
        self.phoenixd.fail_next = 1
        rc, out = self.run_payer()
        self.assertTrue(self.reason(out, txid).startswith("payment_failed"), out)
        self.assertEqual(self.state_lines(), ["%s 30" % TODAY])   # budget reserved, nothing paid
        rc, out = self.run_payer()
        self.assertEqual(self.reason(out, txid), "paid 30 sat")
        self.assertEqual(self.state_lines()[0], "%s 60" % TODAY)  # attempts count
        self.assertEqual(self.state_lines()[1].split(" ")[1], txid)


if __name__ == "__main__":
    unittest.main()
