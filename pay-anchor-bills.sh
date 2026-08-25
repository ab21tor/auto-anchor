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
#                        before any phoenixd contact for the bill; a failing
#                        bill is skipped (records_missing | rate_mismatch)
#                        and the run ends needs_attention. Unset: no audit.
#   DRY_RUN              (strict true/false, default true)
#   STATE_FILE           (default pay-anchor-bills.state beside this script)
#
# The budget counts ATTEMPTS, not confirmed successes: spend is recorded
# before each /payinvoice call and never refunded intra-day — a timeout
# mid-payment may still have paid (fail closed).
#
# Secrets (ANCHOR_BILLS_TOKEN, phoenixd password) go to curl via stdin
# config only — never argv, never echoed, never logged; curl stderr is
# discarded because a config parse error can echo the config (secret) back.
# Error strings are fixed-format and never contain URLs or credentials.
#
# Exit nonzero only when the run itself failed: 2 config or unreadable state
# file, 3 bills fetch, 4 malformed response, 5 state file write. Per-bill
# failures report and continue (exit 0, surfaced as state: needs_attention).
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Invocation env wins over .env: snapshot before sourcing, because set -a
# sourcing would silently overwrite an explicit DRY_RUN=false on the
# command line with a .env default.
ENV_BILLS_URL="${BILLS_URL:-}"
ENV_ANCHOR_BILLS_TOKEN="${ANCHOR_BILLS_TOKEN:-}"
ENV_PHOENIXD_URL="${PHOENIXD_URL:-}"
ENV_MAX_SATS_PER_BILL="${MAX_SATS_PER_BILL:-}"
ENV_DAILY_BUDGET_SATS="${DAILY_BUDGET_SATS:-}"
ENV_AUDIT_PER_RECORD_SATS="${AUDIT_PER_RECORD_SATS:-}"
ENV_DRY_RUN="${DRY_RUN:-}"
ENV_STATE_FILE="${STATE_FILE:-}"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

BILLS_URL="${ENV_BILLS_URL:-${BILLS_URL:-}}"
ANCHOR_BILLS_TOKEN="${ENV_ANCHOR_BILLS_TOKEN:-${ANCHOR_BILLS_TOKEN:-}}"
PHOENIXD_URL="${ENV_PHOENIXD_URL:-${PHOENIXD_URL:-http://127.0.0.1:9740}}"
MAX_SATS_PER_BILL="${ENV_MAX_SATS_PER_BILL:-${MAX_SATS_PER_BILL:-60000}}"
DAILY_BUDGET_SATS="${ENV_DAILY_BUDGET_SATS:-${DAILY_BUDGET_SATS:-200000}}"
AUDIT_PER_RECORD_SATS="${ENV_AUDIT_PER_RECORD_SATS:-${AUDIT_PER_RECORD_SATS:-}}"
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
if [ -s "$STATE_FILE" ]; then
  read -r STATE_DAY STATE_SPENT < "$STATE_FILE"
  case "$STATE_DAY" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail_config "state file unreadable" ;;
  esac
  case "${STATE_SPENT:-}" in
    ''|*[!0-9]*) fail_config "state file unreadable" ;;
  esac
  [ "$STATE_DAY" = "$TODAY" ] && SPENT_TODAY="$STATE_SPENT"
fi

write_state() {
  # write_state <sats> — atomic: tmp file in the same directory + mv. A spend
  # that cannot be recorded must stop the run BEFORE the payment it reserves;
  # bills already paid this run were recorded before their payment.
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")" || {
    echo "state: needs_attention"
    echo "message: cannot write state file"
    exit 5
  }
  printf '%s %s\n' "$TODAY" "$1" > "$tmp"
  mv "$tmp" "$STATE_FILE" || {
    echo "state: needs_attention"
    echo "message: cannot write state file"
    exit 5
  }
}

decode_amount_sats() {
  # decode_amount_sats <bolt11> — echoes the invoice amount in sats, empty on
  # any failure (caller fails closed, the pay402 ceiling rule). The ceiling
  # and budget are enforced on THIS amount, not the gateway's claimed one.
  curl -sS --max-time 15 --config - 2>/dev/null <<EOF | python3 -c 'import sys,json;d=json.load(sys.stdin);a=d.get("amountSat") or (int(d.get("amount",0))//1000 if d.get("amount") else None) or (int(d.get("amountMsat",0))//1000 if d.get("amountMsat") else None);print(a if a else "")' 2>/dev/null
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
echo "spent_today_sats: $SPENT_TODAY"
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
# payable this poll and is dropped; a malformed bill or summary fails the
# whole run (exit 4).
python3 - "$TMP/bills.json" "$TMP/unpaid.tsv" 2>/dev/null <<'PY'
import json, sys

bills_path, tsv_path = sys.argv[1:]
data = json.load(open(bills_path))

bills = data.get("bills")
summary = data.get("summary")
if not isinstance(bills, list) or not isinstance(summary, dict):
    raise SystemExit(1)
unpaid_count = summary.get("unpaid_count")
unpaid_sats = summary.get("unpaid_sats")
if not isinstance(unpaid_count, int) or not isinstance(unpaid_sats, int):
    raise SystemExit(1)

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
    if any(c.isspace() for c in txid + payment_hash + bolt11):
        raise SystemExit(1)
    rows.append((txid, str(amount), "-" if records is None else str(records),
                 payment_hash, bolt11))

with open(tsv_path, "w") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")

print("unpaid_count:", unpaid_count)
print("unpaid_sats:", unpaid_sats)
print("payable_count:", len(rows))
PY
if [ $? -ne 0 ]; then
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
FAILED_COUNT=0
ATTEMPTED=""

# Loop input on fd 3 so nothing inside the loop can ever eat bill lines from
# stdin (the curl helpers read their config from heredocs, not stdin).
while IFS=$'\t' read -r TXID CLAIMED RECORDS PAYHASH BOLT11 <&3; do
  [ -n "$BOLT11" ] || continue

  # Never pay the same invoice twice in one run, whatever the response held.
  case " $ATTEMPTED " in
    *" $PAYHASH "*)
      echo "bill $TXID: skipped reason: already_attempted_this_run"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac

  # Records-rate audit (only when AUDIT_PER_RECORD_SATS is set): the gateway
  # documents amount_sats = records x contracted rate. Runs before any
  # phoenixd contact for the bill; a failing bill flags needs_attention but
  # never aborts the run.
  if [ -n "$AUDIT_PER_RECORD_SATS" ]; then
    case "$RECORDS" in
      ''|-)
        echo "bill $TXID: skipped reason: records_missing"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        AUDIT_SKIPPED=$((AUDIT_SKIPPED + 1))
        continue ;;
    esac
    EXPECTED=$((RECORDS * AUDIT_PER_RECORD_SATS))
    if [ "$RECORDS" -lt 1 ] || [ "$CLAIMED" -ne "$EXPECTED" ]; then
      echo "bill $TXID: skipped reason: rate_mismatch (records $RECORDS x rate $AUDIT_PER_RECORD_SATS sat = $EXPECTED sat, bill claims $CLAIMED sat)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      AUDIT_SKIPPED=$((AUDIT_SKIPPED + 1))
      continue
    fi
  fi

  AMT="$(decode_amount_sats "$BOLT11")"
  case "$AMT" in
    ''|*[!0-9]*)
      echo "bill $TXID: skipped reason: cannot_decode_invoice"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac

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
[ -n "$AUDIT_PER_RECORD_SATS" ] && echo "audit_skipped_count: $AUDIT_SKIPPED"
echo "failed_count: $FAILED_COUNT"
echo "budget_remaining: $((DAILY_BUDGET_SATS - SPENT_TODAY))"

if [ "$FAILED_COUNT" -gt 0 ] || [ "$AUDIT_SKIPPED" -gt 0 ]; then
  echo "state: needs_attention"
elif [ "$DRY_RUN" = "true" ]; then
  echo "state: dry_run_complete"
else
  echo "state: complete"
fi
exit 0
