# auto-anchor

Two tools that pay a timestamp gateway (the `timestamp-gateway`
repository) from a phoenixd. `pay-anchor-bills.sh` is the
standing payer: it polls the gateway's anchor bills, audits every one,
and pays only what passes, within ceilings. `pay402` makes one L402
purchase: one digest, one payment, one proof file. `decode-amount.py`,
beside both, decodes an invoice's amount for them; when the amount cannot
be read, the caller refuses to pay.

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

- **Never the same anchor twice.** The state file carries a paid-txid
  ledger: one `paid <txid> <sats> <utc>` line per anchor this payer has
  ever paid, written the moment the preimage is in hand. A bill whose
  txid is in the ledger is skipped `already_paid_txid`, whatever invoice
  it carries now (a re-served anchor is a gateway defect or a restored
  gateway ledger, never a new debt), and the run ends `needs_attention`.
  Within one run an anchor is attempted once, however many invoices the
  response offers for it, and an invoice is attempted once, however many
  bills carry it (`already_attempted_this_run`).
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
- **Secrets stay out of argv.** The bills token and the phoenixd password
  go to curl via stdin config only: never argv, never logged.

## Requirements

- bash, curl and `python3` (standard library only).
- A phoenixd (by default on this host), its password in
  `~/.phoenix/phoenix.conf`.
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
| `STATE_FILE` | `pay-anchor-bills.state` beside the script | UTC day and sats spent, then the paid-txid ledger |

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

**The records audit.** With `RECORDS_LOG` set, every unpaid bill is also
checked against this client's own record of what it submitted. The count
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
skipped `records_exceed_submissions` with the arithmetic in the line
(`records=N>submitted=M+slack=S,window=A..B`), the run ends
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
the invoice through phoenixd and check the quote against
`MAX_PRICE_SATS` (refusing if the amount cannot be read), pay, redeem,
writing the proof to `PROOF_DIR/<digest>.ots`.

| Setting | Default |
|---|---|
| `GATEWAY_URL` | (required; a trailing slash is tolerated) |
| `MAX_PRICE_SATS` | 5000 |
| `PHOENIXD_URL` | `http://127.0.0.1:9740` |
| `PROOF_DIR` | `~/auto-anchor/proofs` |

Exit codes: 2 bad digest or missing password, 3 no L402 challenge,
4 amount unreadable (refused), 5 quote above the ceiling, 6 payment
returned no preimage, 7 redeem failed.

## Verify

A run reports each bill with its verdict and a refusal's reason in the
line, and ends `needs_attention` when a payment failed or any bill
failed an audit, was malformed, or was an anchor already in the ledger.
The state file is the record of what was paid: the day line, UTC day and
sats spent, then one `paid` line per anchor ever paid.

## Recover

The state file is the only state, written atomically. A run that stopped
mid-way had already recorded each attempt's spend before its payment,
and each paid anchor the moment its preimage was in hand; the next run
reads the file, refuses every anchor in the ledger, and retries a payment
that failed outright. The ledger only grows; a payment that failed
outright is never in it. A corrupt state file,
or a day line dated after today, ends the run `needs_attention` before
any fetch and never silently resets the budget to zero.

## What it does not do

- Escalate a refused bill: a bill above the ceiling or failing an audit
  is skipped on every run with its reason, and the gateway's `/health` is
  what reports it overdue.
- Refund a reservation within the day.
- Run on a schedule of its own.

## Tests

```bash
bash -n pay-anchor-bills.sh
python3 -m unittest discover -s tests
```

Standard library only: a fake gateway and a fake phoenixd on loopback
drive the script through paying, the replay refusals, the audit and
plausibility refusals, the field-shape refusals, the records audit and
the state-file rules. `PAYER_SCRIPT=/path/to/copy` runs the same tests
against another copy of the script (its `decode-amount.py` is taken from
beside the canonical one).
