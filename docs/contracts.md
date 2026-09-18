# Contracts

What each tool in this repository promises, who owns unfinished work at
each handoff, what durable evidence lets a step forget, and which records
are authoritative. Every statement here is made by code named by file and
line in the tree as changed on 2026-09-18 for workflow five, step 1, on
top of revision 51f0208 (branch `main`). A row labelled *current
behaviour* describes that code. A row labelled *required postcondition*
states what must hold and says whether the code makes it hold; where it
does not, a *known defect* row beside it says so. A row labelled
*operating assumption* is something the code relies on and does not
check. Nothing here describes a change that has not been made. The step 0
version of this document, and the gate's eight rulings that shaped step
1, are the operator's session records of 2026-09-18, kept outside the
repositories.

The form follows `docs/contracts.md` of the calendar fork
(`opentimestamps-server` at 4bd1018). The gateway's side of every
exchange below is `timestamp-gateway/docs/contracts.md` (cited as
"gateway G1" and so on).

The words used throughout:

- **Digest**: the 64-hex SHA-256 given on the command line. `pay402`
  never sees what it is a digest of.
- **Proof file**: `PROOF_DIR/<digest>.ots`. It is the completed purchase
  only once it has been checked as one whole OpenTimestamps proof of the
  digest, its bytes fsynced, renamed into place, and its directory
  fsynced.
- **Visible, durable**: a file is *visible* once it has been renamed
  into place; it is *durable* once its bytes and its directory entry
  have both been fsynced. A visible file whose directory fsync failed or
  was interrupted is not known to be durable (gate ruling 1).
- **Sidecar**: `PROOF_DIR/<digest>.l402`, one JSON object: `macaroon`,
  `invoice`, `payment_hash`, `amount_sats`, and once paid `preimage`.
  The record of a purchase in progress: it owns the unfinished work
  until the proof is durable.
- **Lock**: `PROOF_DIR/<digest>.lock`, held by `flock` on fd 9 for the
  whole run. One process per digest.
- **Challenge, token, invoice, payment hash, preimage, settlement**: as
  the gateway's contract defines them.
- **The wallet**: phoenixd, reached with the full `http-password` from
  `~/.phoenix/phoenix.conf`: this tool spends.
- **Checked write**: `atomic-write.py`: a temporary file in the
  destination's directory, fsynced, renamed over the destination, then
  the directory fsynced. A failure before the rename leaves the old
  destination and removes the temporary file. A failure at the directory
  fsync, after the rename, leaves the **new** destination visible with
  its durability uncertain, and exits 1: the helper does not promise
  that the old destination survives every failure (gate ruling 1; its
  docstring says so since step 1).

## 1. What an exit status promises (`pay402`)

| Exit | The promise | What it does not promise |
|---|---|---|
| 0, `paid N sat -> <path>` | The proof file holds bytes that `check-proof.py` accepted as one whole proof of this digest; the bytes were fsynced, the file renamed into place, and the directory fsynced; then the sidecar was removed (`pay402:262-312`) | Not that the proof is anchored: it is pending. Not that the bytes would pass every reader: `check-proof.py` makes the corpus's claim (1) and nothing more (section 6) |
| 0, `already have a valid proof -> <path>` | A proof file was visible and `check-proof.py` accepted it; its bytes and its directory were fsynced by this run; then the sidecar, if any, was removed (92-97) | Not that this run made the purchase: another run did |
| 2 | The digest is not 64 lowercase hex, or the wallet password could not be read (47-48, 99-100). Nothing was contacted | — |
| 3 | The gateway's answer carried no L402 challenge, or its macaroon or invoice failed its shape check (214-223). Nothing paid, nothing written | — |
| 4 | The wallet's decode of the invoice did not yield an amount and a 64-hex payment hash (226-234). Nothing paid, nothing written: a payer that cannot read the hash cannot check a preimage against it | — |
| 5 | The decoded amount exceeds `MAX_PRICE_SATS` (235). Nothing paid, nothing written | — |
| 6 | A payment was attempted and did not return a valid preimage, and the wallet, asked, could not resolve it (247-256), or a sidecar from an earlier run holds an invoice the wallet cannot resolve (192-203). **The sidecar stays**: the invoice and hash are on disk and the next run asks the wallet again. Also 6, with the sidecar removed: the wallet reports the payment definitely not sent (`204`, or a completed unpaid record; 198-200, 253) | Not that nothing was paid: an unresolved attempt may have paid. Nothing is paid again until the wallet answers |
| 7 | The redeem did not answer 200 (271-274), or its body was not a proof of this digest (275-278), or the proof could not be placed (a failure before the rename: nothing is visible, 306-308), or the proof was renamed into place and its directory fsync failed (the proof is visible, not known durable, 302-305), or a valid proof found on disk could not be synced (93). **The sidecar is kept in every case**: the next run redeems from its preimage, or re-establishes the visible proof's durability | — |
| 8 | The sidecar could not be written, or an existing sidecar is unreadable (118-119, 207-208). Before a payment: nothing paid. On an unreadable sidecar: the run stops and the operator moves it aside; nothing is guessed from it | — |
| 9 | Another `pay402` holds the lock for this digest (64-72). Nothing was read, nothing touched | — |

**Ambiguous outcomes across the script.** Every exit above follows the
write it describes. A run killed between a write and its exit leaves the
sidecar in one of the states of section 4, each of which the next run
reads and continues from. No path deletes a sidecar that may hold a paid
or unresolved purchase, or one beside a proof that is not known durable:
the two removals before completion (P1 and P3, `failed`) follow a
positive answer that nothing was paid, and the removal at completion (P0,
P5) follows the directory fsync.

## 2. Records: authoritative, evidence, rebuildable

| Record | Kind | What it is authoritative for | Loss or damage |
|---|---|---|---|
| the proof file `<digest>.ots` | authoritative once durable | The purchase is complete: the bytes passed `check-proof.py`, were fsynced, renamed into place, and the directory was fsynced (283-299, or 74-84 on a rerun). A visible file whose directory fsync did not return is not yet this record: the sidecar still owns the purchase | The proof is the client's only copy; the gateway keeps none (gateway section 3). A lost pending proof cannot be upgraded; a lost anchored proof is a lost proof |
| the sidecar `<digest>.l402` | durable evidence of work in progress | Which invoice was, or is being, paid for this digest, under which token, and, once known, the preimage. Written by checked write before the step it enables (240, 257, 197). Owns the work until the proof is durable | A lost sidecar after a payment and before the redeem is a paid invoice this tool no longer knows about: the wallet still knows (its outgoing record by hash), but nothing here asks without the hash. The next run buys again (a second payment). Operating assumption: `PROOF_DIR` keeps what was renamed into it |
| the lock file `<digest>.lock` | exclusion, never state | Nothing on disk: the lock is the kernel's, on the open file description fd 9 holds (64-72). The file stays after the run | Deleting it while a run holds it lets a second run take a lock on a new file: never removed by code |
| the wallet's outgoing-payment record (`GET /payments/outgoingbyhash/<hash>`) | external, authoritative | What became of an attempt: paid with a preimage, failed, or nothing sent (`204`: phoenixd records an outgoing payment before it sends, README "Requirements") | Reconciliation is impossible while the wallet is down; the sidecar waits (exit 6) |
| the temporary redeem file `<digest>.ots.XXXXXX` | scratch | Nothing: removed by the `EXIT` trap unless renamed (262-263, 303, 310) | A run killed after the redeem leaves one; it is never read |
| `~/.phoenix/phoenix.conf` | credential | The full wallet password | Read into a shell variable and passed to curl by stdin config, never argv (167-169, 226-231, 241-246); not logged |

## 3. Who owns unfinished work

| Handoff | Before | After | Owner in between | Evidence that lets the previous owner forget |
|---|---|---|---|---|
| operator → `pay402` | a digest | the lock held | nobody: nothing owed | — |
| `pay402` → gateway (challenge) | a digest | a token and an invoice in memory | nobody: nothing paid | — |
| memory → sidecar (invoice) | the challenge in memory | the sidecar on disk without a preimage | the sidecar from here: a stop after this write is reconciled, never re-bought blind | the checked write returning (240) |
| `pay402` → wallet (payment) | the sidecar without a preimage | the wallet's outgoing record; the preimage in memory | the wallet, and the sidecar's invoice for asking it | a valid preimage (its SHA-256 the invoice's hash), from the answer or from the wallet's record |
| memory → sidecar (preimage) | the preimage in memory | the sidecar with the preimage | the sidecar: a stop after this write redeems without paying | the checked write returning (257) |
| `pay402` → gateway (redeem) | the sidecar with the preimage | the proof bytes in the temporary file | the sidecar still: a redeem that fails keeps it | the checked bytes fsynced (286-288) |
| proof visible → proof durable | the proof renamed into place (289) | the directory fsynced (294-296) | **the sidecar**: the purchase is unfinished until the directory fsync returns, on the first run and on any rerun (74-84) | the directory fsync returning |
| proof durable → sidecar removed | the proof durable | the sidecar gone | the proof file: the sidecar is now redundant | the `rm -f` (95, 311), not fsynced; a sidecar found again beside a valid proof is synced with it and then removed (P0) |
| pending → attested | the pending proof | the same proof with a Bitcoin attestation | the operator, who asks the gateway's `/upgrade`; nothing in this repository upgrades | the upgraded file |

## 4. `pay402`: one purchase, resumable, one process per digest

### P0. The lock, then the existing-proof check

| Row | Statement | Label |
|---|---|---|
| Authoritative record | the lock (the kernel's, on fd 9); the proof file if durable; the sidecar if the proof is only visible | current behaviour |
| Preconditions | `PROOF_DIR` exists or is made (55); the lock file opens and `flock(LOCK_EX \| LOCK_NB)` succeeds from python on fd 9, which the shell keeps open for the rest of the run (64-72); a second process gets exit 9 at once and reads nothing | current behaviour |
| Side effects, in order | (1) `check-proof.py <file> <digest>` (92); (2) on exit 0: `sync_proof`: fsync the file, fsync its directory (74-84), exit 7 with the sidecar kept if either fails (93); (3) the sidecar removed with `rm -f`, exit 0 (94-96) | current behaviour |
| Visibility and durability | a proof that was only visible is durable after (2) | current behaviour |
| Acknowledgement | `already have a valid proof` | current behaviour |
| Ambiguous outcomes | a proof file that fails the check is left in place and the purchase proceeds; P5 later replaces it only by rename of a checked file. A stop or a failure at (2): the sidecar stands, the next run repeats (2) | current behaviour |
| Intended guarantee | an existing valid proof is never bought again; a visible proof is not a completed purchase until its bytes and its directory are synced, and the sidecar owns the work until then, including on the recovery rerun; one process per digest | required postcondition (met) |
| Tests | `test_an_existing_valid_proof_skips_the_purchase`; `Test_completion_boundary` (both cases: the rerun's own sync is asserted from the injection log, then interrupted again, then converges); `Test_lock.test_a_second_process_for_the_same_digest_is_refused_at_once` (two processes, one exits 9 while the other's payment is held, one payment, one proof, a third run finds it). Before step 1 the sidecar was removed on sight without a sync, reproduced by the gate's probe; and two processes bought twice (review F05) | current behaviour |

### P1. Resume from the sidecar

| Row | Statement | Label |
|---|---|---|
| Authoritative record | the sidecar; for an invoice without a preimage, the wallet's outgoing record | current behaviour |
| Owner of unfinished work | the sidecar, until the proof is durable | current behaviour |
| Preconditions | a sidecar exists; its `macaroon` is base64-shaped, its `invoice` bech32-shaped, its `payment_hash` 64 hex, its `amount_sats` digits (180-187); else exit 8, nothing touched (207-208) | current behaviour |
| Side effects, in order | with a 64-hex `preimage`: nothing, straight to P5 (188-189); without one: (1) `GET /payments/outgoingbyhash/<hash>` (163-170, `outcome_of` 133-161); (2) `paid <preimage>`: the sidecar rewritten with the preimage by checked write (197), then P5; `failed` (`204`, or `isPaid: false` with `completedAt`): the sidecar removed and a fresh purchase from P2 (198-200); anything else (unreachable, non-JSON, a record still in flight): exit 6, the sidecar kept (201-203) | current behaviour |
| Visibility and durability | the rewritten sidecar is durable before the redeem. The fields reach the sidecar helper by stdin, one per line, never argv (102-113) | current behaviour |
| Acknowledgement | `resuming: …` on stdout | current behaviour |
| Ambiguous outcomes | a stop between (1) `paid` and the write at 197: the next run asks again and gets the same answer; a stop after the `rm -f` at 200 and before the new sidecar at 240: nothing owed (the wallet said nothing was sent) | current behaviour |
| Intended guarantees | a sidecar with an invoice and no preimage is put to the wallet before anything is paid; only a definite "not sent" answer starts a new purchase; an unknown answer pays nothing and keeps the record | required postcondition (met) |
| Operating assumption | phoenixd 0.8.0 and 0.9.1 answer `outgoingbyhash` with the best record for the hash and `204` when there is none, and record an outgoing payment before sending (README, "Requirements") | operating assumption |
| Tests | `test_the_invoice_is_on_file_before_paying_and_a_lost_answer_is_reconciled` (the rerun half), `test_garbage_is_never_written_as_a_proof` (the preimage-on-file half), `Test_interruptions.test_death_while_the_wallet_holds_the_payment` (the rerun learns the preimage from the wallet, is killed at the redeem, and the third run redeems from the file) | current behaviour |

### P2. The challenge and the ceiling

| Row | Statement | Label |
|---|---|---|
| Authoritative record | none yet: the challenge is in memory | current behaviour |
| Preconditions | no preimage in hand (212) | current behaviour |
| Side effects, in order | (1) `POST /timestamp` to the gateway, headers only (214); (2) the `WWW-Authenticate` line parsed for `macaroon` and `invoice` (215-217); exit 3 if either is missing or fails its shape check (218-223); (3) `POST /decodeinvoice` at the wallet, the answer read by `decode-invoice.py` into `<sats> <hash>` (226-233); exit 4 if either is unreadable (234); (4) exit 5 if the amount exceeds `MAX_PRICE_SATS` (235) | current behaviour |
| Visibility and durability | nothing written; the gateway now holds an unpaid invoice (gateway G1) | current behaviour |
| Acknowledgement | none until P3 | current behaviour |
| Ambiguous outcomes | a stop anywhere here: nothing paid, nothing owed; the next run takes a new challenge | current behaviour |
| Intended guarantee | the amount and the payment hash enforced are the wallet's decode of the invoice, never the gateway's claim; a quote that cannot be read is refused, never paid | required postcondition (met) |
| Tests | `test_a_purchase_lands_a_checked_proof_and_clears_its_sidecar` (the challenge and decode); the ceiling and the two refusals have no test of their own | current behaviour |

### P3. Persist the invoice, then pay; reconcile a lost answer

| Row | Statement | Label |
|---|---|---|
| Authoritative record | the sidecar (invoice, hash, amount, token); the wallet's outgoing record | current behaviour |
| Owner of unfinished work | the sidecar from its write | current behaviour |
| Preconditions | P2 passed | current behaviour |
| Side effects, in order | (1) the sidecar written by checked write with `macaroon`, `invoice`, `payment_hash`, `amount_sats` (240; exit 8 on failure, nothing paid); (2) `POST /payinvoice` at the wallet, up to 120 s, the answer read by `outcome_of`: `paid <preimage>` only for HTTP 200 with a 64-hex `paymentPreimage` whose SHA-256 is the decoded hash (241-246, 154-155); (3) on anything else, `GET /payments/outgoingbyhash/<hash>`: `paid` continues; `failed` removes the sidecar and exits 6; `unknown` exits 6 with the sidecar kept (247-256) | current behaviour |
| Visibility and durability | (1) durable before the wallet is called: **the invoice is persisted before pay** | current behaviour |
| Acknowledgement | none; P4 follows | current behaviour |
| Ambiguous outcomes | a stop after (1) and before (2): P1 asks the wallet, which answers `204`, and a fresh purchase starts; a stop during (2): the wallet may or may not have paid, and P1 asks it; a stop after (2) and before P4's write: the preimage is lost from memory and P1 recovers it from the wallet. A timeout of the 120 s call is handled as "anything else": the wallet is asked, never assumed unpaid | current behaviour |
| Intended guarantees | no `payinvoice` call is made for an invoice that is not on disk; a payment counts as paid only on a preimage that hashes to the invoice; **a timeout is not evidence of non-payment**: an answer that is not a preimage goes to the wallet, and only its definite answer decides | required postcondition (met) |
| Tests | `test_the_invoice_is_on_file_before_paying_and_a_lost_answer_is_reconciled`, `test_a_purchase_lands_a_checked_proof_and_clears_its_sidecar`, `Test_interruptions.test_death_while_the_wallet_holds_the_payment` (killed inside (2): the sidecar has the invoice and no preimage; the wallet completes the payment; the rerun redeems without paying) | current behaviour |

### P4. Persist the preimage

| Row | Statement | Label |
|---|---|---|
| Authoritative record | the sidecar with `preimage` | current behaviour |
| Side effects | the sidecar rewritten by checked write with the preimage added (257); exit 8 on failure, the preimage then recoverable from the wallet at the next run's P1. The preimage reaches the helper by stdin (102-113) | current behaviour |
| Visibility and durability | durable before the redeem: **the preimage is persisted before redeem** | current behaviour |
| Ambiguous outcomes | a stop after the write: P1's preimage branch redeems without paying | current behaviour |
| Intended guarantee | a paid preimage is on disk before the token is spent on a redeem; neither the macaroon nor the preimage is readable in the process list at any point of the run (gate ruling 8; before step 1 both passed through Python's argument vector) | required postcondition (met) |
| Tests | `test_garbage_is_never_written_as_a_proof`, `Test_argv.test_the_macaroon_the_preimage_and_the_password_never_reach_argv` (a `python3` wrapper first on PATH logs every argv of a purchase and a resume; the macaroon, the preimage and the password never appear; the sidecar holds the right fields), `Test_interruptions.test_death_while_the_gateway_holds_the_redeem` | current behaviour |

### P5. Redeem to a temporary file, check, fsync, rename, fsync the directory

| Row | Statement | Label |
|---|---|---|
| Authoritative record | the proof file, once durable | current behaviour |
| Owner of unfinished work | the sidecar until the directory fsync returns; nothing after it | current behaviour |
| Preconditions | a preimage in hand (P1 or P4) | current behaviour |
| Side effects, in order | (1) `mktemp <proof>.XXXXXX` in `PROOF_DIR`, removed by the `EXIT` trap unless renamed (262-263); (2) `POST /timestamp` with `Authorization: L402 <macaroon>:<preimage>`, the body to the temporary file, up to 60 s (264-270); exit 7 on any status but 200, the temporary file removed by the trap, the proof file untouched (271-274); (3) `check-proof.py <tmp> <digest>`; exit 7 with the reason and nothing written if it refuses (275-278); (4a) `fsync` the temporary file (286-288); (4b) `os.replace` over the proof path: the proof is now **visible** (289); (4c) `fsync` the directory: the proof is now **durable** (294-296); the helper exits 1 for a failure at (4a) or (4b) and 2 for a failure at (4c), and the run exits 7 either way, saying which (300-309); (5) the trap cleared, the sidecar removed with `rm -f` (310-311), the success line | current behaviour |
| Visibility and durability | visible at (4b), durable at (4c). The sidecar owns the purchase until (4c) returns; its removal at (5) is the acknowledgement that the purchase is complete, and it is not fsynced | current behaviour |
| Acknowledgement | exit 0 and `paid N sat -> <path>` | current behaviour |
| Ambiguous outcomes | a stop or a failure between (4b) and (4c): the proof is visible, not known durable, the sidecar standing; on a failure the run says `not known durable`; on a death it says nothing. The next run's P0 fsyncs the file and its directory, and only then removes the sidecar; interrupted again there, it leaves the sidecar again. A stop after (4c) and before (5): durable, the sidecar redundant; P0's sync is then harmless and its removal right. A 200 whose body is not a proof (a paused gateway's JSON, a truncated answer): exit 7, the sidecar with its preimage kept, the next run redeems again without paying. A redeem refused 402 by the gateway (the wallet's settlement not yet visible to it, gateway G2): exit 7, the same | current behaviour |
| Intended guarantees | the proof file is never replaced by bytes that did not pass the check, so an error body or garbage never overwrites an existing proof; a failed redeem never costs a second payment; the sidecar is removed only after the proof and its directory are synced, on this run and on any recovery rerun | required postcondition (met) |
| Tests | `test_a_purchase_lands_a_checked_proof_and_clears_its_sidecar`, `test_garbage_is_never_written_as_a_proof`, `test_a_failed_redeem_never_overwrites_an_existing_proof`, `Test_completion_boundary.test_an_injected_fsync_failure_after_the_rename_is_re_established_by_the_rerun` (exit 7 and `not known durable`; the injection log shows the boundary fired; the rerun interrupted again keeps the sidecar; the clean rerun's file and directory fsync are in the log; one payment, one redeem), `Test_completion_boundary.test_death_at_the_directory_fsync_after_the_rename_is_re_established_by_the_rerun` (returncode -9, no message, the same recovery), `Test_interruptions.test_death_while_the_gateway_holds_the_redeem` (killed inside (2) twice; the sidecar keeps the preimage; no wallet lookup on the way to the proof) | current behaviour |

## 5. Invariants

### The three payment invariants, stated explicitly

1. **A timeout is not evidence of non-payment.** Where it holds: a
   `payinvoice` answer that is not a valid preimage, a dropped connection
   and a 120 s timeout all take the same path: the wallet is asked by
   hash, and only `204` or a completed unpaid record means "not sent"
   (P3, `outcome_of` 133-161); an unreachable wallet is `unknown`, exit
   6, the sidecar kept. Where it is checked:
   `test_the_invoice_is_on_file_before_paying_and_a_lost_answer_is_reconciled`.
2. **Expiry never erases a paid or unresolved obligation.** Where it
   holds: `pay402` reads no clock and no expiry anywhere: a sidecar is
   removed only after the proof is durable (P0, P5) or after the wallet's
   definite answer that nothing was sent (P1, P3). The token's advisory
   expiry is the gateway's not to enforce (gateway G2). Where it is
   checked: the same test, and `test_garbage_is_never_written_as_a_proof`.
3. **A retry reconciles the existing purchase before creating another
   payable attempt.** Where it holds: a run that finds a sidecar never
   takes a new challenge before the wallet has answered for the recorded
   hash (P1 runs before P2); a new purchase starts only from a
   sidecar-free state or from `failed`; and the lock (P0) makes the
   sidecar one process's view, so two starts cannot each see none. Where
   it is checked: the same test, and `Test_lock`. Before step 1 the
   invariant held per process and not across processes (review F05).

### The completion boundary (gate ruling 1)

A visible proof is not a completed purchase. The purchase is complete
when the proof's bytes and its directory entry are both synced, and the
sidecar owns the work until then, on the first run and on every recovery
rerun. Where it holds: P5 (4c) and P0 (2). Where it is checked:
`Test_completion_boundary`, both cases, each with the injection asserted
fired from its log, the recovery interrupted again, and convergence with
one payment and one redeem.

### The seven invariants

| Invariant | Where it holds here | Where it is checked |
|---|---|---|
| Conservation of obligations | from the sidecar's first write until the proof and its directory are synced, the purchase is on disk; a paid preimage is on disk before it is spent; a visible proof of uncertain durability keeps its sidecar | P3, P4, P5, P0 tests |
| Ambiguity is a state | an answer that is not a preimage is `unknown` until the wallet says otherwise, and `unknown` exits 6 keeping the record; an unreadable sidecar is exit 8, never a fresh purchase; a body that is not a proof is exit 7, never a proof file; a proof that is visible but not synced is `not known durable`, exit 7, the record kept | P1, P3, P5 tests; `Test_completion_boundary` |
| Recovery is interruptible | every sidecar write is a checked write; every state a stop can leave, P5's rename included, is one the next run continues from and can be stopped in again: the injected failure and the death at the directory fsync are each repeated on the rerun before the third run converges; the deaths at the wallet call and at the redeem are repeated the same way | `Test_completion_boundary`, `Test_interruptions` |
| Concurrency preserves decisions | one process per digest: the lock is taken before the proof or the sidecar is read and released by the kernel with the process; the second process exits 9 having read nothing | `Test_lock` |
| Safety includes progress | a failed redeem, a paused gateway or an unreachable wallet each end the run with its record kept, and the next run continues; nothing waits forever inside one run (every curl has `--max-time`); the lock is non-blocking | P5 tests, `Test_lock` |
| External effects have retry semantics | a payment's identity is its payment hash; an invoice is paid at most once per digest and reconciled by hash; a redeem is idempotent on the gateway (gateway G3) | P1, P3, P5 |
| Time, capacity, observation | no clock is read; the only bound is `MAX_PRICE_SATS` per purchase; stdout says what happened in fixed lines, stderr says why a run stopped; the wallet password reaches curl by stdin config and the macaroon and preimage reach the sidecar helper by stdin, so none is in the process list; the digest, the payment hash and file paths are in argv and are not secrets | P2, `Test_argv` |
| Anchored is not irreversible | this tool records a pending proof and never says more; whether its block stands is the verifier's business | README "Verify" |

Counting uncertainty never increases a client's charge (rule 6): one
purchase pays one flat price for one digest; nothing here charges per
record.

## 6. The proof reader: three claims kept apart

`check-proof.py` is the gate between "bytes an HTTP answer carried" and
"a proof file on disk". Of the three claims (fork section 6) it makes
(1), *parses*, by the rules the shared corpus pins for every
standard-library reader in this project: the magic, version 1, a
`sha256` file-hash op, exactly this digest, then a tree in which every
branch ends in an attestation, each known attestation payload read to
its last byte (a pending URI of at most 1000 bytes of `A-Z a-z 0-9 - . _
/ :`; a bitcoin height of one varuint), an unknown tag's payload skipped,
a varuint of at most ten bytes, an operand of 1 to 4096 bytes, no message
over 4096 bytes, a fork marker followed by an operation or an
attestation and never another fork, at most 255 operations on a path, and
no byte left over (`check-proof.py`, `check` 97-158, `attestation`
73-95). Its narrowings, shared with the fork's readers: only `sha256`,
`append` and `prepend`, and the ten-byte varuint. It reports the
attestation nodes it read but makes neither claim (2) nor (3): `pay402`
asks only whether the bytes are a proof of the digest, and the file it
writes is pending. `tests/proof_corpus.py` is a byte-identical copy of
the fork's `ops/tests/proof_corpus.py` and the adapter's;
`tests/test_check_proof_corpus.py` runs every case, every strict prefix
and every one-byte extension against the reader, names the two cases the
2026-09-15/16 review reproduced (an empty bitcoin payload, a byte after
the height: review F03, payer half; before step 1 the payload was skipped
by its declared length), fuzzes two thousand mutations for any exception
but `Bad`, and, where `opentimestamps` is importable by the interpreter
running the suite, computes the public client's verdict as the oracle. A
reader that disagrees with the corpus fails the suite.

## 7. Configuration and locking

Configuration reaches `pay402` from the environment only (`GATEWAY_URL`,
`MAX_PRICE_SATS`, `PHOENIXD_URL`, `PROOF_DIR`; 47-53) and the wallet
password from `~/.phoenix/phoenix.conf` (99-100). It reads no `.env`.

| Tool | Used for | Where |
|---|---|---|
| whole-run lock: `flock(LOCK_EX \| LOCK_NB)` on `PROOF_DIR/<digest>.lock`, placed from python on fd 9, which the shell keeps open, so the lock outlives the python process and dies with the shell; a second run exits 9 at once | one process per digest across the whole purchase, from before the proof check to exit | `pay402:64-72` |
| checked write (`atomic-write.py`) | every sidecar write. A failure before the rename keeps the old destination; a failure at the directory fsync after the rename leaves the new destination visible with its durability uncertain, exit 1 | `write_sidecar` 115-120 |
| fsync, `os.replace`, directory fsync | the proof file: exit 1 from the helper before the rename, 2 at the directory fsync after it | `pay402:283-309` |
| fsync of the file and its directory | a valid proof found visible on a rerun, before its sidecar goes | `sync_proof` 74-84, 93 |
| what reaches argv | the wallet password never (curl stdin config); the macaroon and the preimage never (the sidecar helper reads its fields from stdin, 102-113); the payment hash and the digest do (`outcome_of` 133-161, `check-proof.py` 92, 275), and are not secrets | — |

## 8. The standing payer, retired

`pay-anchor-bills.sh`, the standing payer for the gateway's anchor bills,
and its tests were retired from this tree in step 1 of workflow five
(2026-09-18) under the gate's rulings 2 to 4: the anchor-billing feature
it paid is retired from the gateway, and a configuration that charges per
record no longer exists. Findings F17 and F20 of the 2026-09-15/16 review
went with it, unrepaired. Operator data is untouched: on a box that ran
it, `pay-anchor-bills.state` (one `paid` line per anchor ever paid, and
any `attempting` line still unresolved), the `.env` beside the script and
its log stay where they are, ignored by git as before; nothing in this
tree reads them. The reconciliation that precedes the gateway's
retirement of the feature (every attempt and every stored invoice put to
the wallet by lookup, the definitively unpaid written off, the unresolved
kept, nothing minted) is the procedure in
the operator's session record of the step 0 gate (2026-09-18), kept
outside the repositories.

## 9. Assumptions and limits

- No live Lightning payment was made for this document; the suite drives
  `pay402` against a fake gateway and a fake phoenixd on loopback.
- No power loss is simulated: the checked write and the proof's fsyncs
  are what a power cut relies on, and nothing here claims power-loss
  durability (README). The suite injects an `OSError` at the directory
  fsync through a `sitecustomize`, and kills the script there and at the
  wallet call and the redeem; each is a failure at a write boundary or a
  death, not a cut.
- No Linux run: the suite ran on macOS with bash 3.2 and the system
  Python. `flock(1)` is not needed: the lock is Python's `fcntl.flock`
  on a descriptor the shell keeps open.
- `pay402` spends with the wallet's full password; it is the client's
  side and holds what a client holds.
- The proof `pay402` writes is pending; upgrading it is the operator's
  step through the gateway's `/upgrade`, and nothing here does it.
- The macaroon is treated as an opaque base64 string and never parsed
  here: its price caveat is the gateway's to enforce; the ceiling here is
  on the decoded invoice.
- Two hosts sharing nothing can each buy the same digest: the lock is
  per `PROOF_DIR`.
