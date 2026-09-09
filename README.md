# auto-anchor — the paying side

Two tools. `pay-anchor-bills.sh` is the standing payer: it polls the
gateway's anchor bills, audits every one, and pays only what passes,
within ceilings. `pay402` is the single-purchase tool: one digest, one L402
purchase, one proof file.

## pay-anchor-bills.sh

The standing payer's half of the gateway's anchor billing. Polls
`GET /anchor-bills` (bearer-gated) and pays each unpaid bill's bolt11 via
the payer phoenixd — within a per-bill ceiling and a per-UTC-day budget.
`DRY_RUN=true` is the **default**: it lists what would be paid, and still
decodes every bolt11 via phoenixd (read-only), so the preview enforces
exactly the checks a real run would. Only an explicit `DRY_RUN=false`
pays.

### Every knob

Precedence: invocation env > sourced `.env` beside the script > defaults.

| Knob | Default | Meaning |
|---|---|---|
| `BILLS_URL` | (required) | full URL of the gateway's `/anchor-bills` |
| `ANCHOR_BILLS_TOKEN` | (required) | bearer token for `/anchor-bills` |
| `PHOENIXD_URL` | `http://127.0.0.1:9740` | password read from `~/.phoenix/phoenix.conf` |
| `MAX_SATS_PER_BILL` | 60000 | refuse any single bill above this |
| `DAILY_BUDGET_SATS` | 200000 | refuse to exceed this per UTC day |
| `AUDIT_PER_RECORD_SATS` | (unset) | contracted per-record rate; enables the rate audit below |
| `MAX_RECORDS_PER_BILL` | 10000000 | plausibility bound: more records than this, or more sats than exist, is refused as `implausible` |
| `RECORDS_LOG` | (unset) | path of the api-endpoint data log this payer can read; enables the records audit below |
| `RECORDS_SLACK_PCT` | 10 | records audit slack, percent of the window's count |
| `RECORDS_SLACK_RECORDS` | 0 | records audit slack floor, absolute records |
| `DRY_RUN` | `true` | strict true/false |
| `STATE_FILE` | `pay-anchor-bills.state` beside the script | UTC day + sats spent, then the paid-txid ledger |

### Ceilings and sizing

Size `MAX_SATS_PER_BILL`, `DAILY_BUDGET_SATS`, and your outbound channel
capacity to **records-per-anchor-window × the contracted rate** — the
gateway operator guide's "Anchor billing" → "Sizing the payer's ceilings"
carries the arithmetic and a worked example. A bill above the per-bill
ceiling is skipped with `exceeds_per_bill_ceiling` on **every** run,
forever — nothing here escalates it; the gateway's `/health` goes
`billing: overdue` after 24 h, and that is the operator's signal, not
yours.

### Audit behaviour

With `AUDIT_PER_RECORD_SATS` set, every unpaid bill must carry an integer
`records >= 1` and satisfy `amount_sats == records × rate`, decided in
exact integer arithmetic (Python, never the shell) before any phoenixd
contact for that bill. Independently of the rate, a bill claiming more
than `MAX_RECORDS_PER_BILL` records, or more sats than exist, is
`implausible` whatever its arithmetic says. A failing bill is skipped
(`records_missing` | `rate_mismatch` | `implausible`) and the run ends
`needs_attention`. Unset rate: no rate audit, the plausibility bound
stays. The shell never computes on a number the gateway sent: the decoded
invoice amount is bounded to 16 digits before any comparison, and every
sats or records knob must fit 16 digits. The amount enforced against
ceiling and budget is the **decoded invoice's**, never the gateway's
claimed one (fail closed — the pay402 ceiling rule).

### Records audit (opt-in)

With `RECORDS_LOG` set, every unpaid bill is also checked against this
client's own record of what it submitted. The count is sourced from the
api-endpoint's data log (`DATA_DIR/log`, one fixed-format line per event,
UTC timestamp first): every `proof_free` or `proof_bought` line is one
record this client received a proof for. The rotated generation `log.1`
is read too, so size the endpoint's `LOG_CAP_BYTES` to hold at least two
anchor windows. A bill's window is (previous anchor's `confirmed_at`,
this anchor's `confirmed_at`] — the previous anchor being the latest one
in the `/anchor-bills` response with an earlier `confirmed_at`, paid or
not (paid bills stay in the response for a week); with none visible the
window starts at the log's beginning, which can only over-count and so
never refuses wrongly. A bill claiming more `records` than that count
plus slack — `max(RECORDS_SLACK_RECORDS, count × RECORDS_SLACK_PCT / 100)`,
room for the confirmation-delay offset between tree close and
`confirmed_at`, and for resubmissions the calendar counts once more than
the client did — is skipped `records_exceed_submissions` with the
arithmetic in the line (`records=N>submitted=M+slack=S,window=A..B`),
the run ends `needs_attention`, and the other bills are still handled. A
bill without `records`, or without an integer `confirmed_at`, is refused
too (`records_missing`, `records_window_unknown`). An unreadable log is
a config error before any fetch (exit 2): an audit that cannot count
refuses to guess. Proofs the endpoint refused for carrying the wrong
digest are not counted — a box that serves them finds its bills refused.
Unset, nothing here runs: a payer that does not run beside the endpoint
(the Mac's, paying for the Pi) has no log to read and audits by rate and
ceilings only.

### Field shapes

Before any of that, each unpaid bill's strings are checked for shape in
the same Python step: `txid` and `payment_hash` must match
`^[0-9a-f]{64}$`, `bolt11` must be a bech32 string (`ln…`, one case,
bounded). A bill failing a check is skipped (`malformed_txid` |
`malformed_payment_hash` | `malformed_bolt11`) with the offending txid
shown escaped and truncated, never raw; the other bills are still
handled and the run ends `needs_attention`. Nothing but a 64-hex txid
ever reaches the paid ledger, so a gateway cannot poison the state file
(the pre-fix payer paid an uppercase txid, wrote it, and then refused
every later run as "state file unreadable").

### Never the same anchor twice

The state file carries a paid-txid ledger: one `paid <txid> <sats> <utc>`
line per anchor this payer has ever paid, written the moment the preimage
is in hand. A bill whose txid is in the ledger is skipped
`already_paid_txid`, whatever invoice it carries now — a re-served anchor
is a gateway defect or a restored gateway ledger, never a new debt — and
the run ends `needs_attention`. Within one run an anchor is attempted
once, however many invoices the response offers for it, and an invoice
is attempted once, however many bills carry it
(`already_attempted_this_run`). The ledger only grows; a payment that
failed outright is not in it and is retried next run.

### Budget and state

The budget counts **attempts**: spend is recorded before each
`/payinvoice` call and never refunded intra-day — a timeout mid-payment
may still have paid. Bills are paid oldest-anchor-first so budget goes to
the oldest debts. The state file holds the day line — UTC day and sats
spent — followed by the paid-txid ledger, written atomically; a corrupt
state file, or a day line dated after today, ends the run
`needs_attention` before any fetch and never silently resets the budget
to zero. Secrets go to curl via stdin config only — never argv, never
logged.

### Unit tests

```bash
bash -n pay-anchor-bills.sh
python3 -m unittest discover -s tests
```

Stdlib only: a fake gateway and a fake phoenixd on loopback drive the
script through paying, the replay refusals, the audit and plausibility
refusals, the field-shape refusals, the records audit, and the state-file rules.
`PAYER_SCRIPT=/path/to/copy` runs the same tests against another copy of the
script (its `decode-amount.py` is taken from beside the canonical one).

### Running it

Run it manually, or on a schedule. On macOS the natural scheduler is
launchd: a `LaunchAgent` plist with `StartInterval` (e.g. 3600) invoking
the script with its env; keep `DRY_RUN=false` **only** in the scheduled
copy you have audited. No plist ships in this tree — the run cadence and
budget are one decision and belong to whoever holds the wallet.

## pay402 — single purchase

`pay402 <64-hex-digest>` performs one L402 purchase: challenge → decode
the invoice via phoenixd and check the quote against `MAX_PRICE_SATS`
(fail closed if the amount cannot be read) → pay → redeem, writing the
proof to `PROOF_DIR/<digest>.ots`.

| Knob | Default |
|---|---|
| `GATEWAY_URL` | (required; a trailing slash is tolerated) |
| `MAX_PRICE_SATS` | 5000 |
| `PHOENIXD_URL` | `http://127.0.0.1:9740` |
| `PROOF_DIR` | `~/auto-anchor/proofs` |

Exit codes: 2 bad digest / missing password, 3 no L402 challenge,
4 amount unreadable (refused, fail closed), 5 quote above ceiling,
6 payment returned no preimage, 7 redeem failed.
