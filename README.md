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
refusals, and the state-file rules. `PAYER_SCRIPT=/path/to/copy` runs the
same tests against another copy of the script.

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
