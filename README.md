# auto-anchor

One tool that pays a timestamp gateway (the `timestamp-gateway`
repository) from a phoenixd, and four helpers. `pay402` makes one L402
purchase: one digest, one payment, one proof file. Beside it:
`decode-invoice.py` reads an invoice's amount and payment hash out of
phoenixd's decode (when either cannot be read, the caller refuses to
pay); `decode-amount.py` is the amount rule it imports; `atomic-write.py`
is the checked write the purchase record goes through; `check-proof.py`
says whether bytes are one whole OpenTimestamps proof of a digest.

The standing payer for anchor bills (`pay-anchor-bills.sh`) that used to
live here was retired on 2026-09-18 with the gateway's anchor-billing
feature (workflow five; the gate's rulings 2 to 4). On a box that ran it,
its state file, its `.env` and its log are the record of what it paid and
stay where they are; nothing here reads them.

A configuration without a gateway, the calendar alone with the
`api-endpoint` adapter pointed at it by `CALENDAR_URL`, has no Lightning
and nothing for this tool to pay; the `opentimestamps-server` fork's
README, "Install: single host", covers it.

## What pay402 guarantees

Each rule is made by the code and pinned by the test "Tests" names.

- **One process per digest.** The whole run holds an exclusive lock on
  `PROOF_DIR/<digest>.lock` (`flock`, held by the process and released
  by the kernel when it dies, however it dies), taken before anything is
  read. A second `pay402` for the same digest exits 9 at once with
  `another pay402 holds the lock for this digest` and touches nothing.
  The lock file is left in place: removing it would race the next start.
- **The invoice is on file before paying; the preimage before
  redeeming.** The purchase record `PROOF_DIR/<digest>.l402` (macaroon,
  invoice, payment hash, amount; then the preimage) is written through
  `atomic-write.py` before the step it enables. A write that fails stops
  the run (exit 8) before the payment it was recording.
- **Paid means a valid preimage.** A payment counts as paid only when
  `/payinvoice` answered HTTP 200 with a 64-hex `paymentPreimage` whose
  sha256 is the invoice's own payment hash (the one phoenixd decoded from
  the bolt11). Anything else is put to the wallet
  (`GET /payments/outgoingbyhash/<hash>`) before the run gives up: a
  `204`, or a completed unpaid record, means the wallet never sent it;
  anything else is unresolved, exit 6, the record kept, and nothing is
  paid again until the wallet answers. A timeout is never taken as proof
  that nothing was paid.
- **A rerun reconciles before it pays.** A run that finds a purchase
  record redeems from the preimage on file, or asks the wallet what
  became of the recorded payment, before it would take a new challenge;
  a fresh purchase starts only when there is no record or the wallet
  says nothing was sent.
- **The proof is checked, then complete.** The redeem's body goes to a
  temporary file, is checked by `check-proof.py` as one whole proof of
  this digest, fsynced, renamed to `PROOF_DIR/<digest>.ots`, and the
  directory is fsynced; only then is the purchase record removed. An
  error body or garbage never overwrites an existing proof. A proof that
  is visible but whose directory fsync did not return is not yet
  complete: the run says so (exit 7, "not known durable"), keeps the
  record, and the next run fsyncs the file and its directory before it
  removes the record. The same holds for a valid proof found on disk:
  it is synced before the record goes.
- **The wallet password never reaches argv.** It goes to curl by stdin
  config. The macaroon and the preimage go to the helper that writes the
  purchase record by stdin as well, so neither is readable in the process
  list. The digest, the payment hash and file paths do appear in argv;
  none of them is a secret.

## Requirements

- bash, curl and `python3` (standard library only).
- A phoenixd (by default on this host), its password in
  `~/.phoenix/phoenix.conf`. The reconciliation reads
  `GET /payments/outgoingbyhash/<hash>`, present in phoenixd 0.8.0 and
  0.9.1 (checked against their sources).
- The gateway's URL.

## Operate

`pay402 <64-hex-digest>` performs one L402 purchase: challenge, decode
the invoice through phoenixd (amount and payment hash; refusing if either
cannot be read) and check the quote against `MAX_PRICE_SATS`, pay,
redeem, writing the proof to `PROOF_DIR/<digest>.ots`.

| Setting | Default |
|---|---|
| `GATEWAY_URL` | (required; a trailing slash is tolerated) |
| `MAX_PRICE_SATS` | 5000 |
| `PHOENIXD_URL` | `http://127.0.0.1:9740` |
| `PROOF_DIR` | `~/auto-anchor/proofs` |

The proof lands only after the redeem answered 200 and the body checked
as one whole OpenTimestamps proof of this digest (`check-proof.py`): the
body goes to a temporary file first, is checked, fsynced and renamed into
place, and the directory is fsynced, so an existing proof is never
overwritten by an error body or by garbage. An existing valid proof skips
the purchase altogether (after being synced). The purchase state lives in
`PROOF_DIR/<digest>.l402` (macaroon, invoice, payment hash, amount; then
the preimage), written through `atomic-write.py` before the step it
enables, and removed once the proof is complete. A rerun picks up from
it: with a preimage on file it redeems without paying again; with an
invoice and no preimage it asks the wallet what became of the payment
(`GET /payments/outgoingbyhash`) and pays only if the wallet knows
nothing of it.

Exit codes: 2 bad digest or missing password, 3 no L402 challenge,
4 amount or payment hash unreadable (refused), 5 quote above the
ceiling, 6 payment returned no valid preimage and the wallet could not
resolve it (rerun once it answers), 7 redeem failed, answered something
that is not a proof, or the proof could not be placed or synced (the
purchase record is kept; rerun), 8 purchase state unwritable or
unreadable, 9 another `pay402` holds the lock for this digest.

## Recover

The purchase record is the only state. A run that stopped mid-way had
already recorded the invoice before paying and the preimage before
redeeming; the next run reads the record, asks the wallet where the
record does not say, redeems from the preimage where it does, and
re-establishes the durability of a proof that is visible but was not
synced. A record the run cannot read (exit 8) is never guessed from:
move it aside to start over. A run that dies holding the lock releases
it with its process.

`atomic-write.py` is a checked write: a failure before the rename leaves
the old file in place and removes the temporary file; a failure at the
directory fsync after the rename leaves the new file visible with its
durability uncertain. Either way it exits 1 and the caller stops. Nothing
here has been tested against a power cut and nothing here claims
power-loss durability.

## What it does not do

- Upgrade the proof it writes: the proof is pending, and upgrading it is
  the gateway's `/upgrade`.
- Verify a proof against Bitcoin: `check-proof.py` reads structure only.
- Pay a digest twice from one host: the lock refuses a second process,
  and a rerun reconciles. Two hosts sharing nothing are not excluded.
- Establish anything about power loss: its writes are checked and
  fsynced, not tested against a cut.

## Tests

```bash
bash -n pay402
python3 -m unittest discover -s tests
```

Standard library only: a fake gateway and a fake phoenixd on loopback
drive `pay402` through a purchase, a garbage body, a failed redeem, an
existing proof, a lost payment answer reconciled with the wallet; the
completion boundary (an `OSError` injected at the directory fsync through
a `sitecustomize`, and the script killed there, each followed by a rerun
interrupted again and then converging); the lock (two processes, one
payment); process death while the wallet holds the payment and while the
gateway holds the redeem; what reaches argv; and the two failure points
of `atomic-write.py`. `tests/test_check_proof_corpus.py` runs the proof
corpus shared with the calendar fork and the client adapter
(`tests/proof_corpus.py`, a byte-identical copy) against `check-proof.py`
and, where the `opentimestamps` package is importable by the interpreter
running the suite, against the public client as the oracle.
