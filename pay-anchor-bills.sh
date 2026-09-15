#!/usr/bin/env bash
# pay-anchor-bills.sh — the standing payer's half of the gateway's anchor
# billing. Polls GET /anchor-bills (bearer-gated) and pays each unpaid bill's
# bolt11 via the payer phoenixd, within a per-bill ceiling and a per-UTC-day
# budget. DRY_RUN=true (default) lists what WOULD be paid; explicit
# DRY_RUN=false pays. A dry run still decodes each bolt11 via phoenixd
# (read-only) so the preview enforces exactly the checks a real run would.
#
# Config: invocation env > sourced .env beside this script > defaults.
#   BILLS_URL            (required) full URL of the gateway's /anchor-bills
#   ANCHOR_BILLS_TOKEN   (required) bearer token for /anchor-bills
#   PHOENIXD_URL         (default http://127.0.0.1:9740; password read from
#                        ~/.phoenix/phoenix.conf, the pay402 pattern)
#   MAX_SATS_PER_BILL    (default 60000) refuse any single bill above this
#   DAILY_BUDGET_SATS    (default 200000) refuse to exceed this per UTC day
#   NOTE: size both ceilings to expected records-per-anchor-window x the
#                        contracted rate — a bill above MAX_SATS_PER_BILL is
#                        skipped on every run, forever.
#   AUDIT_PER_RECORD_SATS (optional) contracted per-record rate. When set,
#                        every unpaid bill must carry an integer records >= 1
#                        and satisfy amount_sats == records x rate, checked
#                        in exact integer arithmetic before any phoenixd
#                        contact for the bill; a failing bill is skipped
#                        (records_missing | rate_mismatch) and the run ends
#                        needs_attention. Unset: no rate audit.
#   MAX_RECORDS_PER_BILL (default 10000000) plausibility bound: a bill
#                        claiming more records than this, or an amount above
#                        the total bitcoin supply, is refused (implausible)
#                        whatever its arithmetic says, and the run ends
#                        needs_attention. Size it like the ceilings: records
#                        per anchor window, with room.
#   RECORDS_LOG          (optional) path of the api-endpoint data log this
#                        payer can read (its rotated .1 generation is read
#                        too). When set, a bill may not claim more records
#                        than this client's own proof_free + bought
#                        events between the previous anchor's confirmed_at
#                        (exclusive) and its own (inclusive), plus slack;
#                        a bill above that is skipped
#                        (records_exceed_submissions) and the run ends
#                        needs_attention. Unset: no records audit (a payer
#                        that does not run beside the endpoint).
#   RECORDS_SLACK_PCT    (default 10) slack as a percentage of the window's
#                        count; RECORDS_SLACK_RECORDS (default 0) an absolute
#                        floor for it: slack = max(floor, count x pct / 100).
#   DRY_RUN              (strict true/false, default true)
#   STATE_FILE           (default pay-anchor-bills.state beside this script)
#
# The budget counts ATTEMPTS, not confirmed successes: spend is recorded
# before each /payinvoice call and never refunded intra-day — a timeout
# mid-payment may still have paid (fail closed).
#
# The state file is the day line ("<UTC day> <sats spent>") followed by the
# paid-txid ledger: one "paid <txid> <sats> <utc>" line per anchor this
# payer has ever paid, appended the moment a preimage is in hand. A bill
# whose txid is in the ledger is never paid again, whatever invoice it
# carries now (already_paid_txid): a re-served anchor is a gateway defect or
# a restored gateway ledger, never a new debt. A day line dated after today,
# or any other line shape, is corruption and ends the run before any payment.
#
# No arithmetic is done in the shell on a number the gateway sent: the rate
# audit and the plausibility bound run in Python on exact integers, and the
# shell compares only amounts it has bounded to 16 digits. Nor does a string
# the gateway sent reach the shell unchecked: a txid or payment_hash that is
# not 64 lowercase hex, or a bolt11 that is not bech32, is refused per bill
# (malformed_txid | malformed_payment_hash | malformed_bolt11, the txid shown
# escaped and bounded) and the run ends needs_attention.
#
# Secrets (ANCHOR_BILLS_TOKEN, phoenixd password) go to curl via stdin
# config only — never argv, never echoed, never logged; curl stderr is
# discarded because a config parse error can echo the config (secret) back.
# Error strings are fixed-format and never contain URLs or credentials.
#
# Exit nonzero only when the run itself failed: 2 config, unreadable state
# file or unreadable RECORDS_LOG, 3 bills fetch, 4 malformed response, 5
# state file write. Per-bill
# failures report and continue (exit 0, surfaced as state: needs_attention).
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Invocation env wins over .env: snapshot before sourcing, because sourcing
# would silently overwrite an explicit DRY_RUN=false on the command line
# with a .env default.
ENV_BILLS_URL="${BILLS_URL:-}"
ENV_ANCHOR_BILLS_TOKEN="${ANCHOR_BILLS_TOKEN:-}"
ENV_PHOENIXD_URL="${PHOENIXD_URL:-}"
ENV_MAX_SATS_PER_BILL="${MAX_SATS_PER_BILL:-}"
ENV_DAILY_BUDGET_SATS="${DAILY_BUDGET_SATS:-}"
ENV_AUDIT_PER_RECORD_SATS="${AUDIT_PER_RECORD_SATS:-}"
ENV_MAX_RECORDS_PER_BILL="${MAX_RECORDS_PER_BILL:-}"
ENV_RECORDS_LOG="${RECORDS_LOG:-}"
ENV_RECORDS_SLACK_PCT="${RECORDS_SLACK_PCT:-}"
ENV_RECORDS_SLACK_RECORDS="${RECORDS_SLACK_RECORDS:-}"
ENV_DRY_RUN="${DRY_RUN:-}"
ENV_STATE_FILE="${STATE_FILE:-}"

# Sourced as plain shell variables, not exported: nothing from .env (the
# bearer token above all) reaches the environment of curl or python3.
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
fi

BILLS_URL="${ENV_BILLS_URL:-${BILLS_URL:-}}"
ANCHOR_BILLS_TOKEN="${ENV_ANCHOR_BILLS_TOKEN:-${ANCHOR_BILLS_TOKEN:-}}"
PHOENIXD_URL="${ENV_PHOENIXD_URL:-${PHOENIXD_URL:-http://127.0.0.1:9740}}"
MAX_SATS_PER_BILL="${ENV_MAX_SATS_PER_BILL:-${MAX_SATS_PER_BILL:-60000}}"
DAILY_BUDGET_SATS="${ENV_DAILY_BUDGET_SATS:-${DAILY_BUDGET_SATS:-200000}}"
AUDIT_PER_RECORD_SATS="${ENV_AUDIT_PER_RECORD_SATS:-${AUDIT_PER_RECORD_SATS:-}}"
MAX_RECORDS_PER_BILL="${ENV_MAX_RECORDS_PER_BILL:-${MAX_RECORDS_PER_BILL:-10000000}}"
RECORDS_LOG="${ENV_RECORDS_LOG:-${RECORDS_LOG:-}}"
RECORDS_SLACK_PCT="${ENV_RECORDS_SLACK_PCT:-${RECORDS_SLACK_PCT:-10}}"
RECORDS_SLACK_RECORDS="${ENV_RECORDS_SLACK_RECORDS:-${RECORDS_SLACK_RECORDS:-0}}"
DRY_RUN="${ENV_DRY_RUN:-${DRY_RUN:-true}}"
STATE_FILE="${ENV_STATE_FILE:-${STATE_FILE:-$SCRIPT_DIR/pay-anchor-bills.state}}"

fail_config() {
  # fail_config <error-string> — fixed-format, never contains URLs/secrets.
  echo "state: needs_attention"
  echo "message: $1"
  exit 2
}

[ -n "$BILLS_URL" ] || fail_config "BILLS_URL not set"
[ -n "$ANCHOR_BILLS_TOKEN" ] || fail_config "ANCHOR_BILLS_TOKEN not set"
case "$MAX_SATS_PER_BILL" in
  ''|*[!0-9]*) fail_config "MAX_SATS_PER_BILL must be a non-negative integer" ;;
esac
case "$DAILY_BUDGET_SATS" in
  ''|*[!0-9]*) fail_config "DAILY_BUDGET_SATS must be a non-negative integer" ;;
esac
# Empty means the records audit is off. Zero and leading-zero forms are both
# rejected: the rate must be positive, and a leading zero would read as octal
# in the audit arithmetic.
case "$AUDIT_PER_RECORD_SATS" in
  '') ;;
  0*|*[!0-9]*) fail_config "AUDIT_PER_RECORD_SATS must be a positive integer" ;;
esac
case "$MAX_RECORDS_PER_BILL" in
  ''|0*|*[!0-9]*) fail_config "MAX_RECORDS_PER_BILL must be a positive integer" ;;
esac
# The records audit is opt-in: RECORDS_LOG names the api-endpoint data log
# this payer can read. Unreadable is a config error, before any fetch.
if [ -n "$RECORDS_LOG" ]; then
  [ -f "$RECORDS_LOG" ] && [ -r "$RECORDS_LOG" ] || fail_config "RECORDS_LOG is not a readable file"
fi
case "$RECORDS_SLACK_PCT" in
  ''|*[!0-9]*) fail_config "RECORDS_SLACK_PCT must be a non-negative integer" ;;
esac
case "$RECORDS_SLACK_RECORDS" in
  ''|*[!0-9]*) fail_config "RECORDS_SLACK_RECORDS must be a non-negative integer" ;;
esac
# Every knob that reaches shell arithmetic is bounded to 16 digits (above
# the total bitcoin supply in sats): the shell's integers are 64-bit, and
# its comparisons fail open on anything larger.
for KNOB in "$MAX_SATS_PER_BILL" "$DAILY_BUDGET_SATS" "$MAX_RECORDS_PER_BILL" "${AUDIT_PER_RECORD_SATS:-0}" \
            "$RECORDS_SLACK_PCT" "$RECORDS_SLACK_RECORDS"; do
  [ "${#KNOB}" -le 16 ] || fail_config "a sats or records knob exceeds 16 digits"
done
case "$DRY_RUN" in
  true|false) ;;
  *) fail_config "DRY_RUN must be true or false" ;;
esac

PW=$(sed -n 's/^http-password=//p' "$HOME/.phoenix/phoenix.conf" | head -1)
[ -n "$PW" ] || fail_config "no http-password in ~/.phoenix/phoenix.conf"

# Day spend so far. Only an absent/empty file or a well-formed line is
# acceptable: a corrupt file must not silently reset the budget to zero.
TODAY="$(date -u +%Y-%m-%d)"
SPENT_TODAY=0
PAID_LEDGER=""
PAID_TXIDS=""
if [ -s "$STATE_FILE" ]; then
  read -r STATE_DAY STATE_SPENT < "$STATE_FILE"
  case "$STATE_DAY" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail_config "state file unreadable" ;;
  esac
  case "${STATE_SPENT:-}" in
    ''|*[!0-9]*) fail_config "state file unreadable" ;;
  esac
  [ "${#STATE_SPENT}" -le 16 ] || fail_config "state file unreadable"
  # A day line dated after today is not a fresh day: the file was tampered
  # with or the clock moved, and the budget must not silently restart.
  [ "$STATE_DAY" \> "$TODAY" ] && fail_config "state file dated in the future"
  [ "$STATE_DAY" = "$TODAY" ] && SPENT_TODAY="$STATE_SPENT"
  # Every later line is the paid-txid ledger. Any other shape is corruption.
  while IFS=' ' read -r KIND LTXID LSATS LWHEN; do
    [ -n "$KIND" ] || continue
    [ "$KIND" = "paid" ] || fail_config "state file unreadable"
    case "$LTXID" in ''|*[!0-9a-f]*) fail_config "state file unreadable" ;; esac
    PAID_TXIDS="$PAID_TXIDS $LTXID"
    PAID_LEDGER="${PAID_LEDGER}paid $LTXID $LSATS $LWHEN
"
  done <<EOF
$(tail -n +2 "$STATE_FILE")
EOF
fi

write_state() {
  # write_state <sats> — atomic: tmp file in the same directory + mv. A spend
  # that cannot be recorded must stop the run BEFORE the payment it reserves;
  # bills already paid this run were recorded before their payment. The
  # paid-txid ledger is carried along on every write.
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")" || {
    echo "state: needs_attention"
    echo "message: cannot write state file"
    exit 5
  }
  { printf '%s %s\n' "$TODAY" "$1"; printf '%s' "$PAID_LEDGER"; } > "$tmp"
  mv "$tmp" "$STATE_FILE" || {
    echo "state: needs_attention"
    echo "message: cannot write state file"
    exit 5
  }
}

decode_amount_sats() {
  # decode_amount_sats <bolt11> — echoes the invoice amount in sats via
  # decode-amount.py beside this script (shared with pay402), empty on
  # any failure (caller fails closed, the pay402 ceiling rule). The ceiling
  # and budget are enforced on THIS amount, not the gateway's claimed one.
  curl -sS --max-time 15 --config - 2>/dev/null <<EOF | python3 "$SCRIPT_DIR/decode-amount.py" 2>/dev/null
url = "$PHOENIXD_URL/decodeinvoice"
user = ":$PW"
data = "invoice=$1"
EOF
}

pay_invoice() {
  # pay_invoice <bolt11> — echoes the payment preimage, empty on any failure.
  curl -sS --max-time 120 --config - 2>/dev/null <<EOF | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("paymentPreimage",""))' 2>/dev/null
url = "$PHOENIXD_URL/payinvoice"
user = ":$PW"
data = "invoice=$1"
EOF
}

TMP="$(mktemp -d)" || fail_config "cannot create temp dir"
trap 'rm -rf "$TMP"' EXIT

echo "=== pay-anchor-bills ==="
echo "time_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "dry_run: $DRY_RUN"
echo "max_sats_per_bill: $MAX_SATS_PER_BILL"
echo "daily_budget_sats: $DAILY_BUDGET_SATS"
[ -n "$AUDIT_PER_RECORD_SATS" ] && echo "audit_per_record_sats: $AUDIT_PER_RECORD_SATS"
echo "max_records_per_bill: $MAX_RECORDS_PER_BILL"
[ -n "$RECORDS_LOG" ] && echo "records_log: $RECORDS_LOG (slack ${RECORDS_SLACK_PCT}%, at least $RECORDS_SLACK_RECORDS)"
echo "spent_today_sats: $SPENT_TODAY"
echo "paid_ledger_txids: $(echo $PAID_TXIDS | wc -w | tr -d ' ')"
echo

echo "=== fetch bills ==="
# After a laptop sleep the tailnet can take seconds to come back, and a
# first-second fetch times out (curl exit 28). Wait for ANY http answer
# (401 counts: the route is up), max 12 tries x 10s, then proceed
# regardless -- the fetch below keeps its own failure path. Config via
# stdin: URL never in argv.
PROBE_I=0
until [ "$PROBE_I" -ge 12 ]; do
  PROBE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --config - 2>/dev/null <<PROBEEOF
url = "$BILLS_URL"
PROBEEOF
)" && [ -n "$PROBE" ] && [ "$PROBE" != "000" ] && break
  PROBE_I=$((PROBE_I+1))
  sleep 10
done

# --max-time 60: the poll can do a phoenixd round-trip per unpaid bill on the
# gateway side (mint/lookup), so it is slower than a single-RPC call.
HTTP_CODE="$(curl -sS --max-time 60 -o "$TMP/bills.json" -w '%{http_code}' --config - 2>/dev/null <<EOF
url = "$BILLS_URL"
header = "Authorization: Bearer $ANCHOR_BILLS_TOKEN"
EOF
)"
CURL_RC=$?
if [ "$CURL_RC" -ne 0 ]; then
  echo "state: needs_attention"
  echo "message: bills fetch failed (curl exit $CURL_RC)"
  exit 3
fi
if [ "$HTTP_CODE" != "200" ]; then
  echo "state: needs_attention"
  echo "message: bills fetch failed (HTTP $HTTP_CODE)"
  exit 3
fi

# Validate the response and emit unpaid payable bills as TSV, preserving the
# gateway's oldest-anchor-first order so budget goes to the oldest debts.
# An unpaid bill without a bolt11, or without a payment_hash, has nothing
# payable this poll and is dropped; a bill whose txid, payment_hash or
# bolt11 has the wrong shape is refused on its own (malformed_* verdict);
# a response whose structure is wrong fails the whole run (exit 4).
python3 - "$TMP/bills.json" "$TMP/unpaid.tsv" "$AUDIT_PER_RECORD_SATS" "$MAX_RECORDS_PER_BILL" \
        "$RECORDS_LOG" "$RECORDS_SLACK_PCT" "$RECORDS_SLACK_RECORDS" 2>/dev/null <<'PY'
import bisect, calendar, json, re, sys

HEX64 = re.compile(r"^[0-9a-f]{64}$")
# bech32: lowercase or uppercase, never mixed; ln + hrp/data, bounded.
BOLT11 = re.compile(r"^(ln[a-z0-9]{20,4096}|LN[A-Z0-9]{20,4096})$")

(bills_path, tsv_path, rate_raw, max_records_raw,
 records_log, slack_pct_raw, slack_records_raw) = sys.argv[1:]
rate = int(rate_raw) if rate_raw else None
max_records = int(max_records_raw)
slack_pct = int(slack_pct_raw)
slack_records = int(slack_records_raw)
SUPPLY_SATS = 2_100_000_000_000_000
data = json.load(open(bills_path))


def record_times(path):
    """Epoch second of every proof_free / bought line in the
    api-endpoint data log at path and its rotated generation path.1 —
    the client's own count of records it submitted. Exit 2 (config) if
    the log cannot be read: an audit that cannot count refuses to guess."""
    times = []
    days = {}
    for p, required in ((path + ".1", False), (path, True)):
        try:
            fd = open(p, "rb")
        except FileNotFoundError:
            if required:
                raise SystemExit(2)
            continue
        except OSError:
            raise SystemExit(2)
        with fd:
            for line in fd:
                parts = line.split(b" ", 2)
                if len(parts) < 2 or parts[1] not in (b"proof_free", b"bought"):
                    continue
                ts = parts[0]
                if len(ts) != 20:
                    continue
                try:
                    day = ts[:10]
                    base = days.get(day)
                    if base is None:
                        base = calendar.timegm((int(day[:4]), int(day[5:7]), int(day[8:10]), 0, 0, 0))
                        days[day] = base
                    times.append(base + int(ts[11:13]) * 3600 + int(ts[14:16]) * 60 + int(ts[17:19]))
                except ValueError:
                    continue
    times.sort()
    return times


submitted = record_times(records_log) if records_log else None

bills = data.get("bills")
summary = data.get("summary")
if not isinstance(bills, list) or not isinstance(summary, dict):
    raise SystemExit(1)
unpaid_count = summary.get("unpaid_count")
unpaid_sats = summary.get("unpaid_sats")
if not isinstance(unpaid_count, int) or not isinstance(unpaid_sats, int):
    raise SystemExit(1)

# Every anchor the response knows about, paid or not, bounds a window:
# a bill's records are audited against the records this client submitted
# between the previous anchor's confirmed_at and its own.
anchors = sorted(b["confirmed_at"] for b in bills
                 if isinstance(b, dict) and isinstance(b.get("confirmed_at"), int)
                 and not isinstance(b.get("confirmed_at"), bool))

rows = []
for b in bills:
    if not isinstance(b, dict):
        raise SystemExit(1)
    if b.get("status") != "unpaid":
        continue
    txid = b.get("txid")
    amount = b.get("amount_sats")
    records = b.get("records")
    payment_hash = b.get("payment_hash")
    bolt11 = b.get("bolt11")
    if not isinstance(txid, str) or not txid:
        raise SystemExit(1)
    if not isinstance(amount, int) or isinstance(amount, bool) or amount < 0:
        raise SystemExit(1)
    # records is an integer, or null/absent on markup-era bills; any other
    # type is malformed. Only str(int) or "-" reaches the TSV -- never the
    # raw value -- so records cannot inject whitespace the way the isspace
    # check below guards against for the string fields. "-" (not empty)
    # because an empty TSV field would collapse under bash IFS tab splitting.
    if records is not None and (
        not isinstance(records, int) or isinstance(records, bool) or records < 0
    ):
        raise SystemExit(1)
    if not isinstance(bolt11, str) or not bolt11:
        continue
    if not isinstance(payment_hash, str) or not payment_hash:
        continue
    # Field shapes, decided here so nothing but a 64-hex txid, a 64-hex
    # payment_hash and a bech32 bolt11 ever reaches the shell, the state
    # file or the log. A bill failing a shape is refused on its own
    # (malformed_txid | malformed_payment_hash | malformed_bolt11) and the
    # run ends needs_attention; the other bills are still handled. The
    # label shown for a bad txid is its escaped, bounded repr, never the
    # raw bytes (an uppercase or control-character txid once entered the
    # ledger and wedged every later run: full-review D6, 2026-09-08).
    shape = None
    if not HEX64.match(txid):
        shape = ("malformed_txid", "txid is not 64 lowercase hex")
    elif not HEX64.match(payment_hash):
        shape = ("malformed_payment_hash", "payment_hash is not 64 lowercase hex")
    elif not BOLT11.match(bolt11):
        shape = ("malformed_bolt11", "bolt11 is not a bech32 string")
    if shape is not None:
        label = txid if HEX64.match(txid) else ascii(txid)[:80]
        rows.append((label, "-", "-", "-", "-", shape[0], shape[1]))
        continue
    # The rate audit and the plausibility bound are decided here, on exact
    # integers, so the shell never computes on a number the gateway sent.
    # The verdict reaches the shell as one token plus one detail token.
    verdict, detail = "ok", "-"
    if records is not None and records > max_records:
        verdict, detail = "implausible", "records=%d>max_records_per_bill=%d" % (records, max_records)
    elif amount > SUPPLY_SATS:
        verdict, detail = "implausible", "amount=%d>bitcoin_supply" % amount
    elif rate is not None:
        if records is None:
            verdict = "records_missing"
        elif records < 1 or records * rate != amount:
            verdict = "rate_mismatch"
            detail = "records=%d*rate=%d=%d,bill=%d" % (records, rate, records * rate, amount)
    if verdict == "ok" and submitted is not None:
        # The records audit (opt-in, RECORDS_LOG): the box may not bill
        # more records than this client submitted in the anchor's window,
        # plus slack for the confirmation-delay offset and resubmissions.
        confirmed_at = b.get("confirmed_at")
        if records is None:
            verdict = "records_missing"
        elif not isinstance(confirmed_at, int) or isinstance(confirmed_at, bool):
            verdict = "records_window_unknown"
        else:
            earlier = [a for a in anchors if a < confirmed_at]
            prev = max(earlier) if earlier else None
            count = bisect.bisect_right(submitted, confirmed_at) - \
                (bisect.bisect_right(submitted, prev) if prev is not None else 0)
            slack = max(slack_records, count * slack_pct // 100)
            if records > count + slack:
                verdict = "records_exceed_submissions"
                detail = "records=%d>submitted=%d+slack=%d,window=%s..%d" % (
                    records, count, slack, "start" if prev is None else prev, confirmed_at)
    rows.append((txid, str(amount), "-" if records is None else str(records),
                 payment_hash, bolt11, verdict, detail))

with open(tsv_path, "w") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")

print("unpaid_count:", unpaid_count)
print("unpaid_sats:", unpaid_sats)
print("payable_count:", len(rows))
PY
VALIDATOR_RC=$?
if [ "$VALIDATOR_RC" -eq 2 ]; then
  echo "state: needs_attention"
  echo "message: RECORDS_LOG unreadable"
  exit 2
elif [ "$VALIDATOR_RC" -ne 0 ]; then
  echo "state: needs_attention"
  echo "message: malformed bills response"
  exit 4
fi
echo

if [ ! -s "$TMP/unpaid.tsv" ]; then
  echo "state: nothing_due"
  exit 0
fi

echo "=== bills ==="
PAID_COUNT=0
PAID_SATS=0
WOULD_COUNT=0
WOULD_SATS=0
SKIPPED_COUNT=0
AUDIT_SKIPPED=0
REPLAY_SKIPPED=0
MALFORMED_SKIPPED=0
FAILED_COUNT=0
ATTEMPTED=""
ATTEMPTED_TXIDS=""

# Loop input on fd 3 so nothing inside the loop can ever eat bill lines from
# stdin (the curl helpers read their config from heredocs, not stdin).
while IFS=$'\t' read -r TXID CLAIMED RECORDS PAYHASH BOLT11 VERDICT DETAIL <&3; do
  [ -n "$BOLT11" ] || continue

  # A bill whose txid, payment_hash or bolt11 failed its shape check is
  # refused here, before the ledger sees its label: nothing but 64-hex and
  # bech32 strings reach the state file or a phoenixd call.
  case "$VERDICT" in
    malformed_*)
      echo "bill $TXID: skipped reason: $VERDICT ($DETAIL)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      MALFORMED_SKIPPED=$((MALFORMED_SKIPPED + 1))
      continue ;;
  esac

  # Never pay an anchor twice, whatever invoice it carries now: a txid in
  # the paid ledger (any earlier run) is a re-served bill — a gateway
  # defect or a restored gateway ledger, never a new debt — refused loudly.
  case " $PAID_TXIDS " in
    *" $TXID "*)
      echo "bill $TXID: skipped reason: already_paid_txid (this anchor is in the paid ledger; the bill was re-served with payment_hash $PAYHASH)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      REPLAY_SKIPPED=$((REPLAY_SKIPPED + 1))
      continue ;;
  esac

  # Nor twice in one run — by anchor, whether the response repeated the
  # invoice or offered a second one for the same txid — nor the same
  # invoice twice, whatever the response held.
  case " $ATTEMPTED_TXIDS " in
    *" $TXID "*)
      echo "bill $TXID: skipped reason: already_attempted_this_run"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac
  case " $ATTEMPTED " in
    *" $PAYHASH "*)
      echo "bill $TXID: skipped reason: already_attempted_this_run"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac

  # Records-rate audit and plausibility bound, decided in exact integer
  # arithmetic by the validator above. Runs before any phoenixd contact for
  # the bill; a failing bill flags needs_attention but never aborts the run.
  case "$VERDICT" in
    ok) ;;
    *)
      echo "bill $TXID: skipped reason: $VERDICT ($DETAIL)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      AUDIT_SKIPPED=$((AUDIT_SKIPPED + 1))
      continue ;;
  esac

  AMT="$(decode_amount_sats "$BOLT11")"
  case "$AMT" in
    ''|*[!0-9]*)
      echo "bill $TXID: skipped reason: cannot_decode_invoice"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac
  # The decoded amount is the only gateway-sent number the shell computes
  # with: bound it before any comparison, so nothing beyond 64 bits can
  # slip past a comparison that fails open.
  if [ "${#AMT}" -gt 16 ]; then
    echo "bill $TXID: skipped reason: implausible (decoded_amount_exceeds_16_digits)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    AUDIT_SKIPPED=$((AUDIT_SKIPPED + 1))
    continue
  fi

  if [ "$AMT" != "$CLAIMED" ]; then
    echo "bill $TXID: skipped reason: amount_mismatch (invoice $AMT sat, bill $CLAIMED sat)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  if [ "$AMT" -gt "$MAX_SATS_PER_BILL" ]; then
    echo "bill $TXID: skipped reason: exceeds_per_bill_ceiling ($AMT sat > $MAX_SATS_PER_BILL sat)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  REMAINING=$((DAILY_BUDGET_SATS - SPENT_TODAY))
  if [ "$AMT" -gt "$REMAINING" ]; then
    echo "bill $TXID: skipped reason: exceeds_daily_budget ($AMT sat > $REMAINING sat remaining)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  ATTEMPTED="$ATTEMPTED $PAYHASH"
  ATTEMPTED_TXIDS="$ATTEMPTED_TXIDS $TXID"

  if [ "$DRY_RUN" = "true" ]; then
    echo "bill $TXID: would_pay $AMT sat"
    WOULD_COUNT=$((WOULD_COUNT + 1))
    WOULD_SATS=$((WOULD_SATS + AMT))
    SPENT_TODAY=$((SPENT_TODAY + AMT))
    continue
  fi

  # Reserve before paying: an attempt with unknown outcome may still have
  # paid, so it consumes budget and is never refunded intra-day.
  SPENT_TODAY=$((SPENT_TODAY + AMT))
  write_state "$SPENT_TODAY"

  PREIMAGE="$(pay_invoice "$BOLT11")"
  if [ -n "$PREIMAGE" ]; then
    echo "bill $TXID: paid $AMT sat"
    PAID_COUNT=$((PAID_COUNT + 1))
    PAID_SATS=$((PAID_SATS + AMT))
    # Into the paid ledger the moment the preimage is in hand, so no later
    # run can be talked into paying this anchor again.
    PAID_TXIDS="$PAID_TXIDS $TXID"
    PAID_LEDGER="${PAID_LEDGER}paid $TXID $AMT $(date -u +%Y-%m-%dT%H:%M:%SZ)
"
    write_state "$SPENT_TODAY"
  else
    echo "bill $TXID: payment_failed ($AMT sat reserved against budget)"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done 3< "$TMP/unpaid.tsv"
echo

echo "=== summary ==="
if [ "$DRY_RUN" = "true" ]; then
  echo "would_pay_count: $WOULD_COUNT"
  echo "would_pay_sats: $WOULD_SATS"
  echo "budget_spent_today: $SPENT_TODAY (simulated)"
else
  echo "paid_count: $PAID_COUNT"
  echo "paid_sats: $PAID_SATS"
  echo "budget_spent_today: $SPENT_TODAY"
fi
echo "skipped_count: $SKIPPED_COUNT"
echo "audit_skipped_count: $AUDIT_SKIPPED"
echo "replay_skipped_count: $REPLAY_SKIPPED"
echo "malformed_skipped_count: $MALFORMED_SKIPPED"
echo "failed_count: $FAILED_COUNT"
echo "budget_remaining: $((DAILY_BUDGET_SATS - SPENT_TODAY))"

if [ "$FAILED_COUNT" -gt 0 ] || [ "$AUDIT_SKIPPED" -gt 0 ] || [ "$REPLAY_SKIPPED" -gt 0 ] \
   || [ "$MALFORMED_SKIPPED" -gt 0 ]; then
  echo "state: needs_attention"
elif [ "$DRY_RUN" = "true" ]; then
  echo "state: dry_run_complete"
else
  echo "state: complete"
fi
exit 0
