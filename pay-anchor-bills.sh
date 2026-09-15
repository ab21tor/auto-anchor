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
#                        (records_count_discrepancy: "count discrepancy,
#                        review required") and the run ends needs_attention.
#                        This is anomaly detection: an honest batch can
#                        trigger it and a discrepancy never pays more.
#                        Unset: no records audit (a payer that does not run
#                        beside the endpoint).
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
# One run at a time: the whole run — read state, fetch, audit, pay, write —
# holds an exclusive lock on STATE_FILE.lock (flock, held by this shell's
# fd 9 and released by the kernel when the process dies, however it dies).
# A second run, scheduled or by hand, exits 6 at once with
# "another run holds the lock" and touches nothing. Before 2026-09-15 two
# overlapping runs each read the same state, each reserved the full budget,
# and the last writer erased the other's paid-ledger line.
#
# The state file is the day line ("<UTC day> <sats spent>"), then zero or
# more "attempting <txid> <payment_hash> <bolt11> <sats> <utc>" lines, then
# the paid-txid ledger: one "paid <txid> <sats> <utc>" line per anchor this
# payer has ever paid. Every write goes through atomic-write.py beside this
# script (temp file, fsync, rename, directory fsync); a write that fails
# stops the run with exit 5 BEFORE the payment it was recording the
# reservation for, and the last valid state stays on disk.
#
# An "attempting" line is written before the wallet is contacted and names
# the invoice being paid. It is resolved against the wallet
# (GET /payments/outgoingbyhash/<payment_hash>), at the start of every run
# and again right after a payment whose answer was not a valid preimage:
# a payment the wallet reports succeeded (with a 64-hex preimage whose
# sha256 is the payment hash) is entered in the paid ledger; one the wallet
# reports failed, or knows nothing about (204: phoenixd records an outgoing
# payment before it sends, so no record means it never sent), is dropped
# and the anchor becomes payable again; anything else — the wallet
# unreachable, an answer that is neither — stays "attempting", the anchor
# is skipped payment_unresolved on every run until it resolves, and no
# replacement invoice for that txid is ever paid meanwhile. A transport
# failure is never taken as proof that nothing was paid.
#
# A payment counts as paid only when /payinvoice answered HTTP 200 with a
# 64-hex paymentPreimage whose sha256 is the invoice's payment hash (the
# hash phoenixd decoded from the bolt11, never the gateway's claim alone).
# Null, absent or malformed preimages go to reconciliation, never to the
# paid ledger. A bill whose txid is in the ledger is never paid again,
# whatever invoice it carries now (already_paid_txid): a re-served anchor
# is a gateway defect or a restored gateway ledger, never a new debt. A
# day line dated after today, or any other line shape, is corruption and
# ends the run before any payment.
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
# state file write, 6 another run holds the lock. Per-bill failures report
# and continue (exit 0, surfaced as state: needs_attention).
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

# The run lock, taken before the state file is read. fd 9 stays open in
# this shell for the rest of the run; python only places the flock on the
# open file description fd 9 refers to, which this shell keeps, so the lock
# outlives the python process and dies with this one.
LOCK_FILE="${STATE_FILE}.lock"
exec 9>>"$LOCK_FILE" || fail_config "cannot open lock file"
if ! python3 -c 'import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)'; then
  echo "state: needs_attention"
  echo "message: another run holds the lock"
  exit 6
fi

# Day spend so far. Only an absent/empty file or a well-formed line is
# acceptable: a corrupt file must not silently reset the budget to zero.
TODAY="$(date -u +%Y-%m-%d)"
SPENT_TODAY=0
PAID_LEDGER=""
PAID_TXIDS=""
ATTEMPTING_LEDGER=""
ATTEMPTING_LINES=""
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
  # Every later line is an attempting line or the paid-txid ledger. Any
  # other shape is corruption.
  while IFS=' ' read -r KIND LTXID LSATS LWHEN LEXTRA LEXTRA2; do
    [ -n "$KIND" ] || continue
    case "$KIND" in
      paid)
        case "$LTXID" in ''|*[!0-9a-f]*) fail_config "state file unreadable" ;; esac
        PAID_TXIDS="$PAID_TXIDS $LTXID"
        PAID_LEDGER="${PAID_LEDGER}paid $LTXID $LSATS $LWHEN
"
        ;;
      attempting)
        # attempting <txid> <payment_hash> <bolt11> <sats> <utc>
        case "$LTXID" in ''|*[!0-9a-f]*) fail_config "state file unreadable" ;; esac
        case "$LSATS" in ''|*[!0-9a-f]*) fail_config "state file unreadable" ;; esac
        [ -n "$LWHEN" ] && [ -n "$LEXTRA" ] || fail_config "state file unreadable"
        ATTEMPTING_LINES="${ATTEMPTING_LINES}$LTXID $LSATS $LWHEN $LEXTRA ${LEXTRA2:-}
"
        ;;
      *) fail_config "state file unreadable" ;;
    esac
  done <<EOF
$(tail -n +2 "$STATE_FILE")
EOF
fi

write_state() {
  # write_state <sats> — the day line, the attempting lines, then the paid
  # ledger, through atomic-write.py: temp file in the same directory,
  # fsync, rename over the state file, directory fsync. A write that fails
  # stops the run (exit 5) BEFORE the payment whose reservation it was
  # recording; the state file on disk is then the last one written.
  if ! { printf '%s %s\n' "$TODAY" "$1"; printf '%s' "$ATTEMPTING_LEDGER"; printf '%s' "$PAID_LEDGER"; } \
       | python3 "$SCRIPT_DIR/atomic-write.py" "$STATE_FILE" 2>/dev/null; then
    echo "state: needs_attention"
    echo "message: cannot write state file"
    exit 5
  fi
}

decode_invoice() {
  # decode_invoice <bolt11> — echoes "<sats> <payment_hash>" via
  # decode-invoice.py beside this script (shared with pay402), empty on any
  # failure (caller fails closed, the pay402 ceiling rule). The ceiling and
  # budget are enforced on THIS amount, not the gateway's claimed one, and
  # the preimage check on THIS hash, not the gateway's claimed one.
  curl -sS --max-time 15 --config - 2>/dev/null <<EOF | python3 "$SCRIPT_DIR/decode-invoice.py" 2>/dev/null
url = "$PHOENIXD_URL/decodeinvoice"
user = ":$PW"
data = "invoice=$1"
EOF
}

pay_invoice() {
  # pay_invoice <bolt11> <payment_hash> — echoes one of:
  #   paid <preimage>   HTTP 200, a 64-hex paymentPreimage, sha256 = hash
  #   failed            HTTP 200 with phoenixd's PaymentFailed shape (a
  #                     reason and no preimage): the wallet says not sent
  #   unknown           anything else: transport failure, a non-200, a
  #                     null or malformed preimage — to be reconciled
  curl -sS --max-time 120 -w '\n%{http_code}' --config - 2>/dev/null <<EOF | python3 -c '
import hashlib, json, re, sys
raw = sys.stdin.read()
body, _, code = raw.rpartition("\n")
if code.strip() != "200":
    print("unknown"); sys.exit()
try:
    d = json.loads(body)
except ValueError:
    print("unknown"); sys.exit()
if not isinstance(d, dict):
    print("unknown"); sys.exit()
p = d.get("paymentPreimage")
if isinstance(p, str) and re.fullmatch(r"[0-9a-fA-F]{64}", p) and hashlib.sha256(bytes.fromhex(p)).hexdigest() == sys.argv[1]:
    print("paid " + p.lower())
elif p is None and "reason" in d:
    print("failed")
else:
    print("unknown")
' "$2" 2>/dev/null || echo unknown
url = "$PHOENIXD_URL/payinvoice"
user = ":$PW"
data = "invoice=$1"
EOF
}

lookup_payment() {
  # lookup_payment <payment_hash> — asks the wallet what became of an
  # attempt (GET /payments/outgoingbyhash/<hash>; phoenixd 0.8.0 and 0.9.1
  # answer the best record for that hash, 204 when there is none). Echoes:
  #   paid <preimage>   isPaid true with a 64-hex preimage whose sha256 is
  #                     the hash
  #   failed            204 (the wallet never sent it: phoenixd records an
  #                     outgoing payment before sending), or a completed
  #                     record that is not paid
  #   unknown           unreachable, a non-JSON or unexpected answer, or a
  #                     record still in flight (not completed)
  curl -sS --max-time 20 -w '\n%{http_code}' --config - 2>/dev/null <<EOF | python3 -c '
import hashlib, json, re, sys
raw = sys.stdin.read()
body, _, code = raw.rpartition("\n")
code = code.strip()
if code == "204":
    print("failed"); sys.exit()
if code != "200":
    print("unknown"); sys.exit()
try:
    d = json.loads(body)
except ValueError:
    print("unknown"); sys.exit()
if not isinstance(d, dict):
    print("unknown"); sys.exit()
p = d.get("preimage")
if d.get("isPaid") is True and isinstance(p, str) and re.fullmatch(r"[0-9a-fA-F]{64}", p) \
        and hashlib.sha256(bytes.fromhex(p)).hexdigest() == sys.argv[1]:
    print("paid " + p.lower())
elif d.get("isPaid") is False and d.get("completedAt") is not None:
    print("failed")
else:
    print("unknown")
' "$1" 2>/dev/null || echo unknown
url = "$PHOENIXD_URL/payments/outgoingbyhash/$1"
user = ":$PW"
EOF
}

record_paid() {
  # record_paid <txid> <sats> — into the paid ledger the moment a valid
  # preimage is in hand, so no later run can be talked into paying this
  # anchor again; the attempting line for it is dropped.
  PAID_TXIDS="$PAID_TXIDS $1"
  PAID_LEDGER="${PAID_LEDGER}paid $1 $2 $(date -u +%Y-%m-%dT%H:%M:%SZ)
"
  drop_attempting "$1"
}

drop_attempting() {
  # drop_attempting <txid> — remove that anchor's attempting line.
  local kept="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in "attempting $1 "*) ;; *) kept="${kept}${line}
" ;; esac
  done <<EOF
$ATTEMPTING_LEDGER
EOF
  ATTEMPTING_LEDGER="$kept"
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

# Unresolved attempts from earlier runs are settled with the wallet
# BEFORE any bill is fetched: an anchor still unresolved is skipped below
# (payment_unresolved) and no replacement invoice for it is paid.
UNRESOLVED_TXIDS=""
UNRESOLVED_COUNT=0
RECONCILED_PAID=0
RECONCILED_FAILED=0
if [ -n "$ATTEMPTING_LINES" ]; then
  echo "=== reconcile attempts ==="
  while IFS=' ' read -r RTXID RHASH RBOLT11 RSATS RWHEN; do
    [ -n "$RTXID" ] || continue
    # The line is carried until it resolves; rebuilt here so the ledger
    # written below holds exactly the unresolved ones.
    ATTEMPTING_LEDGER="${ATTEMPTING_LEDGER}attempting $RTXID $RHASH $RBOLT11 $RSATS $RWHEN
"
    OUTCOME="$(lookup_payment "$RHASH")"
    case "$OUTCOME" in
      "paid "*)
        echo "attempt $RTXID: paid (wallet holds the preimage; entered in the paid ledger)"
        record_paid "$RTXID" "$RSATS"
        RECONCILED_PAID=$((RECONCILED_PAID + 1)) ;;
      failed)
        echo "attempt $RTXID: payment_failed (wallet reports no successful payment; the anchor is payable again)"
        drop_attempting "$RTXID"
        RECONCILED_FAILED=$((RECONCILED_FAILED + 1)) ;;
      *)
        echo "attempt $RTXID: payment_unresolved (the wallet could not say; kept, no replacement invoice will be paid)"
        UNRESOLVED_TXIDS="$UNRESOLVED_TXIDS $RTXID"
        UNRESOLVED_COUNT=$((UNRESOLVED_COUNT + 1)) ;;
    esac
  done <<EOF
$ATTEMPTING_LINES
EOF
  echo
  if [ "$DRY_RUN" != "true" ]; then
    write_state "$SPENT_TODAY"
  fi
fi

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
                # Anomaly detection, not proof of membership: the window is
                # bounded by confirmation times, and an honest batch's
                # records can lie before its window (README, "The records
                # audit"). A discrepancy is refused for review; it never
                # authorises paying more.
                verdict = "records_count_discrepancy"
                detail = "count discrepancy, review required; records=%d>submitted=%d+slack=%d,window=%s..%d" % (
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

  # An anchor whose earlier attempt the wallet could not resolve is never
  # paid again — not this invoice, not a replacement — until it resolves.
  case " $UNRESOLVED_TXIDS " in
    *" $TXID "*)
      echo "bill $TXID: skipped reason: payment_unresolved (an earlier attempt is unresolved at the wallet; no replacement invoice is paid)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
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

  DECODED="$(decode_invoice "$BOLT11")"
  AMT="${DECODED%% *}"
  DECODED_HASH="${DECODED#* }"
  case "$AMT" in
    ''|*[!0-9]*)
      echo "bill $TXID: skipped reason: cannot_decode_invoice"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac
  case "$DECODED_HASH" in
    ''|*[!0-9a-f]*)
      echo "bill $TXID: skipped reason: cannot_decode_invoice"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue ;;
  esac
  # The invoice's own payment hash is what the preimage is checked
  # against; a bill whose claimed hash is not the invoice's is refused.
  if [ "$DECODED_HASH" != "$PAYHASH" ]; then
    echo "bill $TXID: skipped reason: payment_hash_mismatch (invoice $DECODED_HASH, bill $PAYHASH)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi
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

  # Reserve before paying, and record what is being paid: the attempting
  # line names the anchor, the payment hash and the invoice, so a run that
  # dies here — or a wallet answer that is lost — is reconciled against
  # the wallet next time, never paid again on a replacement invoice. An
  # attempt with unknown outcome may still have paid, so it consumes
  # budget and is never refunded intra-day.
  SPENT_TODAY=$((SPENT_TODAY + AMT))
  ATTEMPTING_LEDGER="${ATTEMPTING_LEDGER}attempting $TXID $PAYHASH $BOLT11 $AMT $(date -u +%Y-%m-%dT%H:%M:%SZ)
"
  write_state "$SPENT_TODAY"

  OUTCOME="$(pay_invoice "$BOLT11" "$PAYHASH")"
  case "$OUTCOME" in
    "paid "*) ;;
    *)
      # Not a valid preimage: the wallet decides what happened, now.
      OUTCOME="$(lookup_payment "$PAYHASH")" ;;
  esac
  case "$OUTCOME" in
    "paid "*)
      echo "bill $TXID: paid $AMT sat"
      PAID_COUNT=$((PAID_COUNT + 1))
      PAID_SATS=$((PAID_SATS + AMT))
      record_paid "$TXID" "$AMT"
      write_state "$SPENT_TODAY" ;;
    failed)
      echo "bill $TXID: payment_failed ($AMT sat reserved against budget)"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      drop_attempting "$TXID"
      write_state "$SPENT_TODAY" ;;
    *)
      echo "bill $TXID: payment_unresolved ($AMT sat reserved against budget; the wallet could not say — kept for reconciliation, no replacement invoice will be paid)"
      UNRESOLVED_COUNT=$((UNRESOLVED_COUNT + 1)) ;;
  esac
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
echo "unresolved_count: $UNRESOLVED_COUNT"
echo "reconciled_paid_count: $RECONCILED_PAID"
echo "reconciled_failed_count: $RECONCILED_FAILED"
echo "budget_remaining: $((DAILY_BUDGET_SATS - SPENT_TODAY))"

if [ "$FAILED_COUNT" -gt 0 ] || [ "$AUDIT_SKIPPED" -gt 0 ] || [ "$REPLAY_SKIPPED" -gt 0 ] \
   || [ "$MALFORMED_SKIPPED" -gt 0 ] || [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  echo "state: needs_attention"
elif [ "$DRY_RUN" = "true" ]; then
  echo "state: dry_run_complete"
else
  echo "state: complete"
fi
exit 0
