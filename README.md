# auto-anchor

Two tools that pay a timestamp gateway (the `timestamp-gateway`
repository) from a phoenixd. `pay-anchor-bills.sh` is the
standing payer: it polls the gateway's anchor bills, audits every one,
and pays only what passes, within ceilings. `pay402` makes one L402
purchase: one digest, one payment, one proof file. Four helpers sit
beside them: `decode-invoice.py` reads an invoice's amount and payment
hash out of phoenixd's decode (when either cannot be read, the caller
refuses to pay); `decode-amount.py` is its amount-only predecessor;
`atomic-write.py` is the checked durable write every state file goes
through; `check-proof.py` says whether bytes are one whole OpenTimestamps
proof of a digest.

A configuration without a gateway, the calendar alone with the
`api-endpoint` adapter pointed at it by `CALENDAR_URL`, has no bills, no
Lightning and nothing for these tools to pay; the `opentimestamps-server`
fork's README, "Install: single host", covers it.

## Configurations

- **Preview or pay.** `DRY_RUN=true` is the default: the run lists what
  would be paid and still decodes every bolt11 through phoenixd
  (read-only), so the preview enforces exactly the checks a real run
  would. Only an explicit `DRY_RUN=false` pays.
- **Which audits.** The per-bill ceiling, the daily budget and the
  plausibility bound always apply. `AUDIT_PER_RECORD_SATS` adds the rate
  audit; `RECORDS_LOG` adds the records audit, which reads the adapter's
  data log, so that payer runs beside the adapter. Each is off when unset.
- **Schedule.** Run it by hand, or on a schedule with its settings in
  the environment. No unit or plist ships in this tree.

## What the payer guarantees

- **One run at a time.** The whole run — read state, fetch, audit, pay,
  write — holds an exclusive lock (`<state file>.lock`, `flock`, held by
  the process and released by the kernel when it dies, however it dies).
  A second run, scheduled or by hand, exits 6 at once with `another run
  holds the lock` and touches nothing.
- **Every state write is checked.** The state file is written through
  `atomic-write.py`: a temporary file in the same directory, fsynced,
  renamed over the state file, the directory fsynced. A write that fails
  stops the run (exit 5) before the payment it was recording the
  reservation for, and the state file on disk is the last one written.
  This is a checked write; nothing here has been tested against a power
  cut and nothing here claims power-loss durability.
- **An attempt is on file before the wallet is called.** Before each
  `/payinvoice` the state file gets an `attempting <txid> <payment_hash>
  <bolt11> <sats> <utc>` line. At the start of every run, and again right
  after a payment whose answer was not a valid preimage, each attempting
  line is put to the wallet (`GET /payments/outgoingbyhash/<hash>`): a
  payment the wallet reports succeeded is entered in the paid ledger; one
  it reports failed, or knows nothing of (204 — phoenixd records an
  outgoing payment before it sends, so no record means it never sent), is
  dropped and the anchor is payable again; anything else stays
  `attempting`, the anchor is skipped `payment_unresolved` on every run
  until the wallet answers, and no replacement invoice for that txid is
  paid meanwhile. A transport failure is never taken as proof that
  nothing was paid.
- **Paid means a valid preimage.** A payment counts as paid only when
  `/payinvoice` answered HTTP 200 with a 64-hex `paymentPreimage` whose
  sha256 is the invoice's own payment hash (the one phoenixd decoded from
  the bolt11; a bill whose claimed `payment_hash` is not the invoice's is
  refused `payment_hash_mismatch`). A null, absent or malformed preimage
  goes to reconciliation, never to the paid ledger.
- **Never the same anchor twice.** The state file carries a paid-txid
  ledger: one `paid <txid> <sats> <utc>` line per anchor this payer has
  ever paid, written the moment a valid preimage is in hand. A bill whose
  txid is in the ledger is skipped `already_paid_txid`, whatever invoice
  it carries now (a re-served anchor is a gateway defect or a restored
  gateway ledger, never a new debt), and the run ends `needs_attention`.
  Within one run an anchor is attempted once, however many invoices the
  response offers for it, and an invoice is attempted once, however many
  bills carry it (`already_attempted_this_run`). With the attempting
  ledger above, an anchor whose payment is unresolved is never paid on a
  replacement invoice either.
- **The budget counts attempts.** Spend is recorded before each
  `/payinvoice` call and never refunded within the day, since a timeout
  mid-payment may still have paid. Bills are paid oldest-anchor-first, so
  budget goes to the oldest debts.
- **The decoded amount is the amount.** The amount enforced against the
  ceiling and the budget is the decoded invoice's, never the gateway's
  claimed one; an amount that cannot be read is not paid. The shell never
  computes on a number the gateway sent: the decoded invoice amount is
  bounded to 16 digits before any comparison, and every sats or records
  setting must fit 16 digits.
- **Audits before payment.** Every audit for a bill is decided in Python,
  in exact integer arithmetic, before any phoenixd contact for that bill.
  The records audit is anomaly detection, not proof of batch membership
  ("The records audit"): a discrepancy is refused for review and never
  authorises paying more.
- **Secrets stay out of argv.** The bills token and the phoenixd password
  go to curl via stdin config only: never argv, never logged.

## Requirements

- bash, curl and `python3` (standard library only).
- A phoenixd (by default on this host), its password in
  `~/.phoenix/phoenix.conf`. The reconciliation reads
  `GET /payments/outgoingbyhash/<hash>`, present in phoenixd 0.8.0 and
  0.9.1 (checked against their sources).
- For `pay-anchor-bills.sh`, the gateway's `/anchor-bills` URL and its
  bearer token; for `pay402`, the gateway's URL.

## Operate

### `pay-anchor-bills.sh`

Precedence: invocation environment, then the sourced `.env` beside the
script, then defaults.

| Setting | Default | Meaning |
|---|---|---|
| `BILLS_URL` | (required) | full URL of the gateway's `/anchor-bills` |
| `ANCHOR_BILLS_TOKEN` | (required) | bearer token for `/anchor-bills` |
| `PHOENIXD_URL` | `http://127.0.0.1:9740` | password read from `~/.phoenix/phoenix.conf` |
| `MAX_SATS_PER_BILL` | 60000 | refuse any single bill above this |
| `DAILY_BUDGET_SATS` | 200000 | refuse to exceed this per UTC day |
| `AUDIT_PER_RECORD_SATS` | (unset) | contracted per-record rate; enables the rate audit |
| `MAX_RECORDS_PER_BILL` | 10000000 | plausibility bound: more records than this, or more sats than exist, is refused as `implausible` |
| `RECORDS_LOG` | (unset) | path of the `api-endpoint` data log this payer can read; enables the records audit |
| `RECORDS_SLACK_PCT` | 10 | records audit slack, percent of the window's count |
| `RECORDS_SLACK_RECORDS` | 0 | records audit slack floor, absolute records |
| `DRY_RUN` | `true` | strict true/false |
| `STATE_FILE` | `pay-anchor-bills.state` beside the script | UTC day and sats spent, then the attempting lines, then the paid-txid ledger; `<STATE_FILE>.lock` beside it is the run lock |

**Ceilings.** Size `MAX_SATS_PER_BILL`, `DAILY_BUDGET_SATS` and the
outbound channel capacity to records-per-anchor-window × the contracted
rate; the gateway operator guide's "Anchor billing", under "Sizing the
payer's ceilings", carries the arithmetic and a worked example. A bill
above the per-bill ceiling is skipped with `exceeds_per_bill_ceiling` on
every run; nothing here escalates it. The gateway's `/health` reports
`billing: overdue` after 24 h.

**The rate audit.** With `AUDIT_PER_RECORD_SATS` set, every unpaid bill
must carry an integer `records >= 1` and satisfy
`amount_sats == records × rate`. Independently of the rate, a bill
claiming more than `MAX_RECORDS_PER_BILL` records, or more sats than
exist, is `implausible` whatever its arithmetic says. A failing bill is
skipped (`records_missing` | `rate_mismatch` | `implausible`) and the run
ends `needs_attention`. Unset, there is no rate audit; the plausibility
bound stays.

**The records audit.** Anomaly detection, not an audit of batch
membership: it compares a bill's `records` with a count of this client's
own proof events in a time window bounded by confirmation times, and the
calendar assigns records to batches by aggregation, not by confirmation.
An honest bill can trigger it — records submitted while the previous
anchor was still waiting to confirm belong to the next batch but fall
before that batch's window — and no slack setting can eliminate that,
since the count in such a window can be zero. A refused bill is a
discrepancy for the operator to review (`records_count_discrepancy`:
"count discrepancy, review required"); the audit never authorises paying
more than a bill claims, only refusing it. With `RECORDS_LOG` set, every
unpaid bill is checked against this client's own record of what it
submitted. The count
is sourced from the `api-endpoint` adapter's data log (`DATA_DIR/log`,
one fixed-format line per event, UTC timestamp first): every `proof_free`
or `bought` line, the adapter's free-door and paid-door proof events, is
one record this client received a proof for. The rotated generation
`log.1` is read too, so the adapter's `LOG_CAP_BYTES` must hold at least
two anchor windows. A bill's window is (previous anchor's
`confirmed_at`, this anchor's `confirmed_at`], the
previous anchor being the latest one in the `/anchor-bills` response with
an earlier `confirmed_at`, paid or not (paid bills stay in the response
for a week); with none visible the window starts at the log's beginning,
which can only over-count and so never refuses wrongly. A bill claiming
more `records` than that count plus slack,
`max(RECORDS_SLACK_RECORDS, count × RECORDS_SLACK_PCT / 100)`, room for
the confirmation-delay offset between tree close and `confirmed_at` and
for resubmissions the calendar counts once more than the client did, is
skipped `records_count_discrepancy` with the arithmetic in the line
(`count discrepancy, review required; records=N>submitted=M+slack=S,window=A..B`), the run ends
`needs_attention`, and the other bills are still handled. A bill without
`records`, or without an integer `confirmed_at`, is refused too
(`records_missing`, `records_window_unknown`). An unreadable log is a
config error before any fetch (exit 2). Proofs the adapter refused for
carrying the wrong digest are not counted. Unset, nothing here runs and
the payer audits by rate and ceilings only.

**Field shapes.** Before any of that, each unpaid bill's strings are
checked for shape in the same Python step: `txid` and `payment_hash`
must match `^[0-9a-f]{64}$`, `bolt11` must be a bech32 string (`ln…`,
one case, bounded). A bill failing a check is skipped (`malformed_txid` |
`malformed_payment_hash` | `malformed_bolt11`) with the offending txid
shown escaped and truncated, never raw; the other bills are still handled
and the run ends `needs_attention`. Nothing but a 64-hex txid ever
reaches the paid ledger, so a gateway response cannot write anything else
into the state file.

### `pay402`

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
place, so an existing proof is never overwritten by an error body or by
garbage. An existing valid proof skips the purchase altogether. The
purchase state lives in `PROOF_DIR/<digest>.l402` (macaroon, invoice,
payment hash, amount; then the preimage), written through
`atomic-write.py` before the step it enables — the invoice before paying,
the preimage before redeeming — and removed once the proof is on disk. A
rerun picks up from it: with a preimage on file it redeems without
paying again; with an invoice and no preimage it asks the wallet what
became of the payment (`GET /payments/outgoingbyhash`) and pays only if
the wallet knows nothing of it. Paid means the same thing as for the
payer: HTTP 200, a 64-hex preimage, its sha256 the invoice's payment
hash.

Exit codes: 2 bad digest or missing password, 3 no L402 challenge,
4 amount or payment hash unreadable (refused), 5 quote above the
ceiling, 6 payment returned no valid preimage and the wallet could not
resolve it (rerun once it answers), 7 redeem failed or answered
something that is not a proof (the paid preimage is kept; rerun to
redeem), 8 purchase state unwritable or unreadable.

## Verify

A run reports each bill with its verdict and a refusal's reason in the
line, each earlier attempt with how the wallet resolved it (`attempt
<txid>: paid | payment_failed | payment_unresolved`), and ends
`needs_attention` when a payment failed or is unresolved, or any bill
failed an audit, was malformed, or was an anchor already in the ledger.
The state file is the record: the day line, UTC day and sats spent; one
`attempting` line per payment the wallet has not yet accounted for; then
one `paid` line per anchor ever paid.

## Recover

The state file is the only state, written checked and atomically. A run
that stopped mid-way had already recorded each attempt — its reservation
and its `attempting` line — before its payment, and each paid anchor the
moment a valid preimage was in hand; the next run reconciles every
attempting line with the wallet before fetching a bill, refuses every
anchor in the ledger, and retries a payment the wallet reports failed.
The ledger only grows; a payment that failed outright is never in it. A
corrupt state file, or a day line dated after today, ends the run
`needs_attention` before any fetch and never silently resets the budget
to zero. A run that dies holding the lock releases it with its process.

## What it does not do

- Escalate a refused bill: a bill above the ceiling or failing an audit
  is skipped on every run with its reason, and the gateway's `/health` is
  what reports it overdue.
- Refund a reservation within the day.
- Run on a schedule of its own.
- Prove that a bill's records were in its anchor's batch: the records
  audit is anomaly detection ("The records audit").
- Establish anything about power loss: its writes are checked and
  fsynced, not tested against a cut.

## Tests

```bash
bash -n pay-anchor-bills.sh
python3 -m unittest discover -s tests
```

Standard library only: a fake gateway and a fake phoenixd on loopback
(with `/payments/outgoingbyhash`, and ways to lose an answer, answer a
null preimage, refuse, or hold a payment open) drive the script through
paying, the replay refusals, the audit and plausibility refusals, the
field-shape refusals, the records audit, the state-file rules, the
cross-process lock, the checked write, the reconciliation of lost
answers and null preimages, and `pay402` against a fake gateway. The
2026-09-15 review's findings are `Test_review_2026_09_15` and
`Test_pay402`. `PAYER_SCRIPT=/path/to/copy` runs the same tests against
another copy of the script (the helpers are taken from beside the
canonical one).
