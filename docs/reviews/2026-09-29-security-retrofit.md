# Security retrofit — 2026-09-29

Base: `origin/main` at `1138e2cad37f265b648144a0793f647f23dd30e7`.
Branch: `codex/codex-security`, in a separate managed worktree. Claude's working tree was not modified.
Immutable baseline audit: Codex Security scan `3ece2d4d-a324-4d79-9239-42d3f94180e6`.

The Codex Security audit identified 14 findings (one high, eleven medium, two low). The highest risk was plaintext staging alongside encrypted exports, where a shared destination could expose data before encryption completed. The remaining findings concern confidentiality downgrade, resource exhaustion, malformed imported data and untrusted SQLite structures. This audit did not demonstrate remote code execution.

A supplemental closure review found one more medium-severity issue: encrypted files were read into memory without a limit and encryption assembled another large integer list. The sealed baseline audit remains unchanged; this record therefore covers **15 findings** in total.

## Findings and changes

| Finding | Severity | Implemented response |
| --- | --- | --- |
| Plaintext beside encrypted full/selected export | High | Stage in a unique private system temporary directory; clean up on success and failure. |
| Secure-storage error silently becomes plaintext export | Medium | Propagate failure and stop export, sync and sending. Manual decryption may use a one-time entered password. |
| Encrypted folder sync accepts plaintext downgrade | Medium | Reject plaintext while a passphrase is configured; retain explicit manual legacy import. |
| Unbounded partial LAN uploads | Medium | Four active uploads, two per source address, 600 MiB reserved capacity, 30-second idle and 15-minute absolute deadlines; bounded streamed writes and cleanup. |
| Discovery retains arbitrary peers indefinitely | Medium | Expire after 10 seconds, retain at most 256 peers, bound packet/field sizes and notification work. |
| Non-object discovery JSON throws a type error | Medium | Validate root and field types before use. |
| Unauthenticated recipient names expose plaintext payloads | Medium | GUI sending requires an existing shared passphrase; show address and unverified identity. Individual device authentication remains absent. |
| XLSX decompression precedes size enforcement | Medium | Preflight ZIP directory, reject unsupported/encrypted/link members, inflate with an actual-output limit and retain CRC verification. Reject ambiguous end records. |
| Sparse XLSX coordinates cause large dense allocations | Medium | Validate coordinates and reserve aggregate row/cell budgets before allocation. |
| Exchange SQLite views/triggers execute before validation | Medium | Allow only supported inert schema definitions before metadata/migration and recheck on the locked connection. |
| Invalid change history poisons later consumers | Medium | Validate history field types, identifiers, timestamps and JSON before transactional import. |
| Nested Ex marks and chosen snapshots can crash consumers | Medium | Validate supported Ex type tokens and nested snapshot rows/outcomes; retain valid historical snapshots. |
| File picker loads oversized content before checking | Low | Enforce declared and actual streamed byte limits before constructing memory buffers. |
| Exchange picker makes unbounded temporary disk copies | Low | Bound streamed copies and remove partial directories on failure and after use. |
| Unbounded whole-message encryption buffers (supplement) | Medium | Limit the complete encrypted envelope to 128 MiB before allocation/key derivation; use one size-bounded input buffer, reject changed lengths, decrypt through buffer views and write envelope components without a giant spread list. |

An independent patch review also found and corrected two lifecycle regressions: manual encrypted recovery when secure storage is unavailable, and cleanup of decrypted files if a page closes while decryption is running.

## Compatibility and limits

- SIQE1 encryption and existing exchange data formats are unchanged; no dependencies, accounts, permission system or server were added.
- GUI LAN sending requires a passphrase. Sharing that passphrase gives payload decryption capability; it does not prove a peer's identity or prevent replay. The low-level LAN transport remains usable by core callers and is not an authenticated transport protocol.
- Manual plaintext import remains intentional. Local live databases, normal unencrypted exports and recovery snapshots are not automatically encrypted at rest.
- XLSX: compressed input 20 MiB, at most 2,048 members, expanded total 100 MiB, aggregate 200,000 logical rows and 2,000,000 allocated cells. These are explicit resource limits, not Excel's maximum format dimensions.
- App memory picker: 20 MiB. Exchange picker: 2 GiB. LAN: 300 MiB per file and the concurrency/time limits above. Trusted integrations can configure picker/LAN limits in code.
- Encrypted SIQE1 files: 128 MiB including the 50-byte envelope. Existing larger encrypted backups are rejected with a size error; smaller selected exports are required. This is an explicit compatibility tradeoff to bound whole-message cryptographic memory use, not a streaming-encryption implementation. Plaintext manual imports retain the separate disk-copy limit. Password retry applies only to authentication failures, not size or file-read errors.
- Exchange schema checks accept schemas produced by supported application versions. Hand-edited SQLite files with extra tables, views, triggers or custom indexes are intentionally rejected.
- Private temporary staging reduces shared-folder disclosure; it is not secure erasure and does not protect against an attacker controlling the operating system.

## Verification

Core: `dart test --timeout 3m --concurrency=2 --reporter expanded` passed all **219 tests**, including the supplemental oversized-envelope test. `dart analyze` reported no issues. The ten LAN security tests also passed three consecutive targeted runs. TCP reset handling in tests accepts only ECONNRESET; unrelated socket errors and missed deadlines still fail.

App: the complete Flutter suite passed **91 tests**, including visually reviewed goldens. Only the exchange screen golden was updated for intentional security copy. After the supplemental typed authentication-error change, **11 core crypto/share tests** and **12 app boundary/localization/import/restore tests** passed, including oversized-file refusal and wrong-password retry followed by successful decryption. Final `flutter analyze --no-pub` reported no issues. Proxy environment variables were unset so local test websocket/HTTP connections reached the test server. `git diff --check` was clean.

The installed `cryptography 2.9.0` AES-GCM implementation was inspected before accepting the capacity tradeoff. Its default stream state collects all chunks and concatenates them before encryption/decryption (`lib/src/cryptography/cipher.dart`, `_DefaultCipherState`); `DartAesGcm` has no bounded-state override and its incremental MAC API is unimplemented. A simple switch to `encryptStream`/`decryptStream` would therefore not fix peak memory. The 128 MiB threshold is a conservative product limit, not a measured safe-memory guarantee on every device. Supporting larger encrypted backups without whole-message buffering requires a separately reviewed implementation and compatibility testing.

### Performance evidence and limits

The unchanged repository benchmark generated 100,000 quotations, 20,000 products, 10,000 suppliers and 130,500 history rows. Baseline export/import took 7,042/26,429 ms. Its existing supplier-table, newest-quotation-page and usable-price-page gates failed (19,506 ms vs 3,000; 2,000 vs 1,000; 4,403 vs 1,500). These failures predate this patch.

A later full-size comparison was stopped during the unchanged baseline because host contention made even export take 38,039 ms. No post-patch full-size performance pass is claimed. A bounded comparison used identical generated shapes (100 suppliers, 200 products, one project, 1,000 quotations), one initial run and three repeated rounds per version:

| Operation | Baseline range, ms | Hardened range, ms |
| --- | ---: | ---: |
| Export | 120–196 | 67–134 |
| Import into empty library | 322–739 | 157–1,675 |
| Idempotent re-import | 46–92 | 35–325 |
| Supplier rows | 6–9 | 5–15 |
| Product rows | 17–33 | 14–72 |
| Newest quote page | 25–55 | 20–125 |
| Usable-price quote page | 29–140 | 25–139 |

The initial hardened run was slower even in unchanged query paths; subsequent hardened import rounds were 545, 260 and 157 ms. These noisy macOS JIT measurements show that the operations complete at the bounded sample size, but do not isolate security overhead or establish a statistically reliable regression/improvement claim. Large-library performance on an idle host remains **DEFERRED**. Resource checks are bounded/streamed; no new per-query security work or dependency was added.

Security tests include malicious ZIP metadata and coordinates, schema views/triggers, malformed history/snapshots, LAN flood/timeout/cleanup cases, secure-store failures and picker overflow. Functional suites cover ordinary exchange, merge idempotency, older-schema migration, backups/restoration, Excel import/export and specification workflows.

Coverage focuses on trust boundaries: LAN discovery/HTTP, data-package import/export, encrypted staging, folder synchronization, file picking and downstream imported-data consumers. Other UI, static dictionaries, generated platform code and dependencies were not exhaustively reviewed. Dependency advisory intelligence was unavailable through the optional Daybreak service. Passing macOS-hosted tests does not establish Android/Windows device behavior, Office/WPS interoperability, production performance or absence of further vulnerabilities.
