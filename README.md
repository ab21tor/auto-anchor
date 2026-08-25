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
| `AUDIT_PER_RECORD_SATS` | (unset) | contracted per-record rate; enables the audit below |
| `DRY_RUN` | `true` | strict true/false |
| `STATE_FILE` | `pay-anchor-bills.state` beside the script | UTC day + sats spent |

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
`records >= 1` and satisfy `amount_sats == records × rate` — checked
before any phoenixd contact for that bill. A failing bill is skipped
(`records_missing` | `rate_mismatch`) and the run ends
`needs_attention`. Unset: no audit. The amount enforced against ceiling
and budget is the **decoded invoice's**, never the gateway's claimed one
(fail closed — the pay402 ceiling rule).

### Budget and state

The budget counts **attempts**: spend is recorded before each
`/payinvoice` call and never refunded intra-day — a timeout mid-payment
may still have paid. Bills are paid oldest-anchor-first so budget goes to
the oldest debts. The state file holds one line — UTC day and sats spent —
written atomically; a corrupt state file ends the run `needs_attention`
and never silently resets the budget to zero. Secrets go to curl via
stdin config only — never argv, never logged.

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
