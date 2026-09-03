# GPT-Pro(GPT-5.6 Sol) 검토 — D17-C r1 (public dev 2a3f447 기준, 2026-09-03)

> 요청 프롬프트: ink scratchpad gpt-c-r1-prompt.final.md. 평결 NO-GO(P0 10건). r2(eddy 라이더)와 겹치는 항목과 새 항목의 접합은 review/d17-c-r3-dashboard.md §10.

# Verdict

**NO-GO.**

I verified that `dev` resolves to `2a3f44702f2030a1ad991132cfe60a09a29878b8` and reviewed the requested files at that commit.

The overall shape—one source-owned per-node snapshot, local conduit as sole writer, generation-checked replacement, and an on-demand read-only dashboard—is sound. The r1 normative text is not ready to brief because it currently permits false “listening” claims, makes freshness transport-dependent, leaves the rsync path outside the generation guard, contradicts its own omission invariant when truncated, and reserves the wrong gateway identity while forbidding the recipient address B will need.

The minimum P0 set is:

1. Define an ear row from the **owned lease and its exact registration**, using the full ring-time gate.
2. Make truncated snapshots incomplete/unknown, not evidence of non-listening.
3. Add `written-at`, local `seen-at` normalization, and a clock-skew/progress rule.
4. Put rsync `.ear` transmission and installation through the same validation and generation guard.
5. Reject malformed incoming snapshots instead of replacing a valid one.
6. Backport `.ear` tolerance to 0.8.2 or add a fleet-wide enable gate.
7. Replace the empty shutdown snapshot with an explicit transitional state.
8. Restrict 0.9.0 HTTP to loopback, or require transport encryption for non-loopback.
9. Define principal classes and reserve `khala-gateway`; do not globally forbid addressing it.
10. Make the v1 snapshot/API extensible enough for gateway and operator telemetry.

---

## Q1. Snapshot format

The proposed 12-token line is **not sufficient or fully safe**. `truncated <n>` is the right kind of completeness signal, but the 64-line cap and current omission semantics are not. Add `written-at`; do not add a self-declared digest.

1. **P0 — r1 §3.1 and §6, identity selection and `route`.**

**Evidence:** Actual ringing begins from an owned lease and its `lease.InstanceID` registration in `link/conduit.go:336-414`. Before a doorbell, the code additionally requires matching lease epoch, PID, PID-start token, Claude session ID, and registration lease epoch at `link/conduit.go:829-833`. r1 defines `route != none` from registration verification and socket fields alone and does not define which registration wins when an identity has multiple registrations.

**Failure:** A verified non-owner registration can yield `route socket` while the owned lease refers to a different or stale registration. The snapshot says “listening”; `maybeRing` writes only a failed journal and no doorbell.

**Smallest change:** For each identity, first resolve the current `state=owned` lease, then select exactly `registrations[lease.instanceId]`. Set `listening=yes` only if the complete `maybeRing` lease/registration gate passes. With no valid owned lease, set `route none`. Specify deterministic behavior for orphaned and multiple registrations.
2. **P0 — r1 §3.1, route vocabulary.**

**Evidence:** At ring time a non-empty channel socket is dynamically verified and attempted even when `ChannelVerified` is false; on success an unverified channel may be accompanied by a socket echo, and on failure the conduit falls back to the socket: `link/conduit.go:853-886`.

**Failure:** The proposed `channel | socket | none` projection can disagree with actual `via=channel+socket` and fallback behavior.

**Smallest change:** Separate `listening yes|no` from advisory `route channel|channel+socket|socket|none`, or define `route` as the currently usable preferred path after the same checks used by `maybeRing`.
3. **P0 — r1 §3.1, token grammar.**

**Evidence:** `CCVersion` enters from an environment variable, CLI flag, or Claude registry and is stored without a token grammar or length bound in `link/runtime.go:697-830`. A version containing whitespace or a newline breaks a fixed whitespace-token row. Counts and epochs also have no per-token bounds in r1.

**Smallest change:** Define exact maximum lengths and grammars for every value. Encode unconstrained strings such as version as bounded base64url/percent-encoding, or restrict them to a documented safe token grammar. Reject rows with missing, duplicate, or extra positional tokens.
4. **P0 — r1 §3.1 and §6.2, truncation.**

**Evidence:** There are seven fixed header lines. Under a total 64-line cap, reserving the final line for `truncated <n>` leaves at most **56 identity rows**, not 64. r1 simultaneously says that an absent identity means not listening.

**Failure:** On a node with 60 identities, four alphabetically later identities are absent and therefore falsely reported as not listening.

**Smallest change:** Define `complete yes|no` or make `truncated <n>` explicitly change absence semantics to **unknown**. Increase the limit to at least 256 identity rows and a corresponding byte cap, or remove the separate 64-line limit and retain a byte/record-count bound.
5. **P0 — r1 §3.1, pending and drain telemetry.**

**Evidence:** B6 required `last-drained-generation`, but the proposed row contains only the last-drain epoch. It also publishes only the first eight hex digits of the SHA-256 generation. The earlier requirement is explicit in `review/gpt-pro-d17-review.md:625-744`; current generation production is full SHA-256 at `link/conduit.go:744-758`.

**Failure:** A 32-bit generation tag can collide across long-lived generation churn, and an epoch alone cannot prove that the current pending generation was the one drained.

**Smallest change:** Carry the complete 64-hex generation and complete `last-drained-generation`, using `-` for absent values. Add a principal class and pending counts by future lane now; see Q10.
6. **P0 — r1 §3.1/§3.2, missing `written-at`.**

**Evidence:** `generation=max(now,last+1)` is an ordering token, not a trustworthy wall clock after clock rollback or rapid same-second writes. The row’s first-seen, last-ring, and last-drain fields are writer epochs that a remote reader otherwise has no common reference for.

**Smallest change:** Add `written-at <writer-epoch>`. Treat `generation` as opaque monotonic ordering only. Derive remote event ages from `written-at - event-at`, then add locally observed snapshot age; do not directly subtract writer event epochs from the reader clock.
7. **P2 — r1 §3.1, digest.**

**Evidence:** Native offers already bind bytes to SHA-256, and equal-generation conflict detection can compare the incoming bytes/digest with the existing file. An in-file digest is unauthenticated and would require a special canonicalization rule to avoid self-reference.

**Smallest change:** Do not add a digest. Preserve/quarantine equal-generation conflicting bytes and log both transport digests. Ed25519 in B can sign canonical envelope bytes directly.
8. **P2 — r1 §3.1/§5.4, replicated `mailbox` and component version.**

**Evidence:** The line exposes logical node aliases but not `peer` SSH coordinates. Prior C2 explicitly asked for component versions while forbidding raw config and SSH coordinates.

**Conclusion:** I do not object under the declared all-user-owned-fleet threat model. `conduit <version>` is useful operational metadata. `mailbox <names...>` is mild topology disclosure.

**Smallest change:** None required. For stricter minimization, publish `role hub|spoke` or a sorted logical mailbox list rather than raw config ordering.

---

## Q2. Freshness

The code confirms both transport facts, but the resulting rule is **not sound** under both transports or under clock skew. A stale snapshot can look fresh.

1. **P0 — r1 §3.2 and §6.3, mtime semantics.**

**Evidence:** Native receive writes a new temporary inode and renames it, with no `Chtimes`, so destination mtime is receiver installation time: `link/install.go:146-187,223-250`. The fallback always invokes `rsync -a`, which preserves source mtime: `bin/khala:1803-1868`, especially `bin/khala:1857`. Presence is pulled directly at `bin/khala:2025-2030`.

**Failure scenarios:**
  - A conduit stopped at 10:00, leaving an old snapshot. At 12:00 the link reconnects and installs it through the native path. Its destination mtime becomes 12:00 and it appears fresh for another two intervals.
  - A source clock one hour ahead gives a stale snapshot a future mtime. Under the literal test `now - mtime <= 2*interval`, the negative age is fresh until the reader clock catches up.
  - A snapshot installed recently on a relay through the native path acquires a new mtime, which rsync then preserves to later readers.

  **Smallest change:** Normalize every accepted installation, including fallback rsync, through one installer that records a node-local `seen-at`. Add `written-at`. Either:
  - state a bounded clock-skew assumption and require both recent `seen-at` and plausible `written-at`; or
  - for clock-independent liveness, treat a first observation as `warming/unknown` and require observation of a strictly higher generation within the expected interval before declaring it fresh. Persist the two observations in node-local runtime state.
2. **P1 — r1 §3.2, future timestamps and pruning.**

**Evidence:** r1 also proposes pruning `.ear` by inode mtime. On the rsync path, that timestamp may be a future source timestamp.

**Failure:** A future-dated stale snapshot can remain both “fresh” and retention-ineligible for an arbitrarily long local interval.

**Smallest change:** Require `0 <= now-seenAt`; never use source-preserved inode mtime for freshness or retention. Prune from the receiver-local `seen-at` sidecar. Treat impossible/future metadata as invalid or unknown, not fresh.
3. **P1 — r1 §3.2, passive freshness limit.**

**Evidence:** No passive file rule can distinguish “newly received but old content” from “newly produced content” under unbounded clock skew if only one generation has ever been observed.

**Smallest change:** State this explicitly. Use generation progress for the strong guarantee; use `written-at` only for event-age calculation and plausibility diagnostics.

---

## Q3. Install guard

The proposed guard is bypassed by fallback rsync. It matters despite mtime-based freshness.

1. **P0 — r1 §3.2 and §8, fallback bypass.**

**Evidence:** The Go guard would execute only inside `installer.receive`. Fallback rsync pulls the entire mailbox `presence/` directly into the destination directory at `bin/khala:2025-2030`; it never invokes the installer. The fallback’s source-owned presence push globs at `bin/khala:2018-2024` do not include `conduit@<self>.ear` at all.

**Failure:** Fallback nodes do not originate their own snapshot, but can import and overwrite remote `.ear` files without parsing or generation checks. A lower generation recently installed at the mailbox may still look fresh.

**Smallest change:** Add the source-owned `.ear` to fallback push. Pull `.ear` files into a staging directory, validate them, run the same generation matrix as native receive, atomically install, and update local `seen-at`. Exclude `.ear` from the existing direct presence merge.
2. **P1 — r1 §3.2, rsync quick-check.**

**Evidence:** `rsync -a` normally decides transfer from size and mtime, not content. Mutable equal-size snapshots written close together can therefore be skipped on implementations/filesystems with insufficient timestamp resolution.

**Smallest change:** Use `--checksum` for staged `.ear` transfers. The objects are tiny; this does not justify an in-file digest.
3. **P0 — r1 §3.2, malformed incoming replacement.**

**Evidence:** r1 says that if parsing the incoming generation fails, the incoming file replaces the existing file. Readers then ignore the malformed installed snapshot.

**Failure:** One malformed or partial source snapshot destroys a valid higher-generation view and suppresses all listener information until another update arrives.

**Smallest change:** Use this matrix:
  - incoming invalid → quarantine/drop incoming, keep existing;
  - existing invalid and incoming valid → replace;
  - incoming generation lower → drop;
  - equal and identical → no-op;
  - equal and different → keep existing and quarantine incoming;
  - higher valid → replace.
4. **P1 — r1 §3.2, equal-generation conflict evidence.**

**Evidence:** r1 retains the existing file and logs, but discards the conflicting incoming bytes. Prior C1 explicitly required quarantining equal-generation/different-byte conflicts.

**Smallest change:** Preserve the conflicting file under a bounded quarantine path with source node, generation, and digest in the log. Do not expose it through the dashboard.
5. **P1 — r1 §3.1/§3.2, accepted basename scope.**

**Evidence:** `presenceNode` accepts **any** valid identity prefix ending in `.ear`, not only `conduit@<node>.ear`: `link/config.go:102-116`. The native destination similarly accepts any such presence basename: `link/install.go:35-59`.

**Failure:** `foo@alpha.ear` can be replicated and may be mistaken for a second node snapshot by a permissive reader.

**Smallest change:** Snapshot readers and the new `.ear` install guard must accept only the exact basename `conduit@<node>.ear`, and require the internal `node` field to match that suffix. Other `.ear` files remain ignored or quarantined.

---

## Q4. Rollout order

The hard-fail claim is half correct. `khala presence` always fails; `reconcile` does not fail every pass under the 0.8.1 hotfix.

1. **P2 — r1 §7 and factsheet open question 2, factual correction.**

**Evidence:** `cmd_presence` skips only `.watching` and `.watcher`; an `.ear` reaches `valid_address`, emits an error, and returns 1: `bin/khala:5019-5107`, specifically the check at approximately `5047-5053`. This happens on every invocation.

`prune_presence` likewise treats `.ear` as an invalid heartbeat: `bin/khala:2702-2753`. However, `reconcile_cycle` calls it only when the retention sweep is due: `bin/khala:2787-2842`. The default `retention-interval` is 300 seconds, not every pass.

**Smallest change:** Change r1/factsheet wording to: “presence fails on every invocation; reconcile fails on each due presence-retention sweep—every pass only when `retention-interval 0`.”
2. **P0 — r1 §7, order safety.**

**Evidence:** An ear produced on one upgraded node replicates to every reachable old-CLI node. Checking only the writer node’s CLI version does not protect those remote nodes.

**Failure:** `conduit 0.9` observes local `khala 0.9` and writes the file; a remote 0.8.1 CLI receives it and loses `khala presence`, regardless of the writer’s local check.

**Smallest change:** Add `.ear`-tolerant skip/prune handling to the in-flight 0.8.2 CLI, roll 0.8.2 to every node, and only then permit an ear producer. This is substantially safer than relying on a 0.9-only ordered rollout.
3. **P0 — r1 §7, producer enablement.**

**Evidence:** During a rolling link-binary upgrade, old receivers also lack the proposed native generation guard, even though they already accept `.ear`.

**Smallest change:** Default ear production off behind a local config/capability switch. Enable it only after the fleet has both a tolerant CLI and guarded link/fallback installers. A per-node check of one local CLI executable is not sufficient; a fleet enable point is.
4. **P1 — r1 §7, suggested local semver probe.**

**Conclusion:** A conduit search for “the local CLI ≥0.9” is not worth the reverse-discovery/version-skew complexity. `khala-link` currently has no authoritative reverse mapping to the CLI selected by every hook or fallback path; CLI-to-link selection is one-way at `bin/khala:4202-4229`.

**Smallest change:** Use the 0.8.2 compatibility backport plus explicit fleet enablement. Do not dynamically probe arbitrary local CLI paths.

---

## Q5. Drain stamp

`run/drained/<identity>` is an appropriate node-local primitive, but the proposed epoch-only semantic is insufficient for B6.

1. **P0 — r1 §3.3 and §6.8, missing generation.**

**Evidence:** The earlier B6 requirement includes `last-drained-generation`; r1 writes only `<epoch> <letters> <notices> <streams>`. Current drain supports selective and bounded modes: `bin/khala:4674-5017`.

**Failure:** Pending ring generation `G` remains. `khala inbox --notices-only` consumes only an info notice and updates the epoch. A dashboard cannot tell that the recent drain did not touch `G`. A bounded partial drain has a similar ambiguity.

**Smallest change:** Record at least:

```
drain 1 <at> <before-generation|-> <after-generation|-> \
  <ring-drained> <info-drained> <streams> <ok|partial>
```

Publish the applicable full generation as `last-drained-generation` in the snapshot.
2. **P1 — r1 §3.3, stamp consistency with the drain lock.**

**Evidence:** The current drain holds `brain.lock.d` from `bin/khala:4816` through its mutations and releases it at approximately `5008`; the summary is printed afterward at `5014-5015`.

**Failure:** Implementing “immediately before the summary” literally places the stamp after lock release, allowing reconcile/new delivery to change the generation between drain completion and stamp creation.

**Smallest change:** Compute the post-drain generation and atomically replace the stamp **before releasing** `brain.lock.d`, after all committed inbox/cursor mutations.
3. **P1 — r1 §3.3, partial failures.**

**Evidence:** Current code can move letters successfully and later fail while preparing notices or advancing a stream cursor, returning nonzero after real mutations: `bin/khala:4838-5007`. r1 says no stamp on drain failure.

**Failure:** Real consumption becomes invisible and B6 can falsely report that no drain occurred.

**Smallest change:** If zero state changes committed, write no stamp. If any state change committed, write `status partial` with committed counts and before/after generation even when the command ultimately returns nonzero.
4. **P1 — r1 §3.3/§8, cheapest generation source.**

**Evidence:** Bash has no current access to the conduit generation; it is calculated by Go’s `letterGeneration` at `link/conduit.go:744-758`. The doorbell carries it, but generic socket-initiated or manual drains do not receive the frame as an argument.

**Smallest change:** Add a small read-only command such as:

```
khala-link runtime pending-generation --identity <name>
```

returning full generation and counts using the same `pending`/`letterGeneration` code. Invoke it before and after the drain while the brain lock is held. Do not duplicate SHA-256 generation semantics in Bash.
5. **P1 — r1 §3.1/§3.3, “last drain” versus “last current-generation drain.”**

**Evidence:** A drain epoch describes activity; it does not prove completion of the current generation.

**Smallest change:** Keep both `last-drain-at` and `last-drained-generation`. B6 clears/suppresses only from generation evidence or an empty pending set, not from a recent epoch alone.

---

## Q6. Snapshot write cadence

The pending-field lag is acceptable for the proposed thresholds. The clean-shutdown empty snapshot is not correctly typed.

1. **P2 — r1 §3.1 and §9.3, periodic pending lag.**

**Evidence:** At a 60-second interval, pending count and generation publication lag by at most roughly one interval plus replication delay. This is small relative to 15-minute and 60-minute B6 thresholds.

**Smallest change:** None. Alert only from a fresh, complete snapshot and include the interval/propagation uncertainty in threshold evaluation.
2. **P0 — r1 §3.1/§6.6, empty shutdown snapshot.**

**Evidence:** systemd uses `Restart=on-failure` and launchd uses `KeepAlive`: `bin/khala:4299-4366`. Explicit service restart and launchd restart can produce a clean shutdown immediately followed by startup. Deletions do not propagate.

**Failure:** The empty snapshot may replicate while the replacement startup snapshot is delayed or lost, producing a fresh false “nobody listening” view during a routine restart.

**Smallest change:** Add top-level `state running|stopping`. On clean shutdown write `state stopping` with no identities. Readers display/suppress it as transitional/unknown, not as authoritative non-listening. The next startup writes higher-generation `state running`.
3. **P1 — r1 §3.1, startup ordering.**

**Evidence:** Current conduit startup performs an initial scan in `conduit.run`; listener truth is populated from that scan. Writing “at start” before the initial verification/lease scan would emit another false empty snapshot.

**Smallest change:** Define the startup write as occurring only after the first successful complete scan. If runtime loading fails, write no running snapshot.
4. **P1 — r1 §3.1/§8, first-seen persistence.**

**Evidence:** Current `conduitState` has no `firstSeen` field: `link/conduit.go:52-59`. It is deleted when nothing is pending and restored only from delivery journals: `link/conduit.go:397-399,926-983`. A registration’s `StartedAt` is session lifetime, not pending-generation first observation.

**Failure:** A conduit restart can reset a 14-minute pending generation to age zero, or there may be no journal from which to restore it when no valid owner existed.

**Smallest change:** Persist generation, generation-first-seen, successful-written-ring count, and last-written-ring in a bounded node-local sidecar. Do not derive pending first-seen from registration `StartedAt`.
5. **P1 — r1 §3.1, written-ring count.**

**Evidence:** `attemptIndex` increments before delivery and therefore includes failed attempts: `link/conduit.go:810-833`. The proposed field is “number of written bells.”

**Smallest change:** Count only journals with `status=written`, or persist a separate successful-write counter. Do not expose `attemptIndex` as written-ring count.
6. **P1 — r1 §3.1, generation churn masking old pending work.**

**Evidence:** Any newly arrived or partially drained ring letter changes the ID-set hash. A sole generation-first-seen field resets even if an older letter remains pending.

**Smallest change:** Add `oldest-ring-pending-at` independently of generation-first-seen, or persist per-letter recipient-local installed time. Keep generation-first-seen for once-per-generation notification deduplication.

---

## Q7. Dashboard security

Good choices as written are: a mandatory high-entropy bearer, loopback default, no query-string token, no CORS, no mutating API, `POST` rejection, `Cache-Control: no-store`, embedded assets, and explicit text gating. The following changes remain.

1. **P0 — r1 §5.1/§5.5/§6.9, arbitrary non-loopback plaintext HTTP.**

**Evidence:** Requiring a token file for a non-loopback bind authenticates requests but does not protect the bearer in transit. `--listen 0.0.0.0:47000` would expose plaintext Authorization headers on every host interface.

**Smallest change:** Make 0.9.0 loopback-only. Alternatively, permit non-loopback only with TLS, or only on an explicitly validated encrypted tailnet address with wildcard/LAN binds rejected. A token-file requirement alone is insufficient.
2. **P1 — r1 §5.1, token-file loading.**

**Evidence:** The design does not specify ownership, mode, symlink, or size checks.

**Smallest change:** Open with no-follow semantics; require a regular file owned by the effective UID with no group/other permissions; apply a small size limit; accept exactly one normalized token; reject trailing non-whitespace data. Read once at startup.
3. **P1 — r1 §5.1/§5.5, constant-time comparison contract.**

**Evidence:** `subtle.ConstantTimeCompare` is only fixed-work for equal-length inputs. The presented Authorization value is client-controlled in length.

**Smallest change:** Decode both to fixed 32-byte values or hash both values to fixed-size arrays before constant-time comparison. A length leak is not consequential here, but the implementation should match the stated invariant.
4. **P1 — r1 §5.2, `localStorage`.**

**Evidence:** Browser origin storage is keyed by scheme/host/port, not Unix UID or server process. Another process can later bind the same unprivileged loopback port after the dashboard exits. A persistent `--token-file` token stored under that origin can then be read by same-origin script.

**Conclusion:** `localStorage` is not acceptable for the token on a multi-user host. For random-per-run tokens it is also pointless because the stored value becomes stale.

**Smallest change:** Keep the token only in JavaScript memory. Optionally accept it initially through the URL fragment, immediately remove the fragment with `history.replaceState`, and never place it in persistent or session origin storage.
5. **P1 — r1 §5.5, filesystem opening.**

**Evidence:** An `Lstat` followed by `ReadFile` is a TOCTOU pair. Existing `openRegular` already opens the final component with `O_NOFOLLOW` and validates the resulting file descriptor: `link/install.go:93-119`. It still does not by itself protect symlinked parent components.

**Smallest change:** Open through the file descriptor after validation. For inbox/minds/streams, walk from an already-open trusted root with `openat`/no-follow checks for each directory component, or explicitly validate each parent as a real owned directory. Apply per-file size limits.
6. **P1 — r1 §5.4, `/api/letter?id=` locator.**

**Evidence:** `messageIDPattern` permits only digits, dots, lowercase alphanumeric/hyphen names, and `@`: `link/config.go:16-18`. It excludes slash, backslash, NUL, and percent after query decoding, so it is safe as a basename. It has no length bound. More importantly, a message ID encodes the **sender**, not the recipient inbox directory.

**Failure:** `id` alone does not identify `inbox/<recipient>/{new,cur}/<id>`. Searching and returning the first duplicate is nondeterministic.

**Smallest change:** Either pass a separately validated `identity` plus `id`, or issue an opaque server-side letter key from `/api/fleet`. Search only trusted local identity directories, reject ambiguous duplicates, cap ID length to a filesystem-safe limit, and verify the opened file’s `Id:` equals its basename.
7. **P1 — r1 §5.2/§5.5, DOM rendering.**

**Evidence:** Subjects, bodies, focus, stance, sender text, and version strings are file-derived. The CSP does not prevent DOM XSS caused by assigning those strings to `innerHTML`. `sanitizePreview` is unsuitable as a general browser boundary because it pre-escapes `&<>` and will display double-escaped when safely rendered through `textContent`.

**Smallest change:** Require `encoding/json` and DOM `textContent`/attribute APIs only; prohibit `innerHTML`, template concatenation, and HTML event attributes. Add explicit tests with `</script>`, `<img onerror>`, quotes, invalid UTF-8, and bidi controls.
8. **P1 — r1 §5.5, CSP completeness.**

**Evidence:** The proposed CSP is a strong base but lacks directives not inherited from `default-src`.

**Smallest change:** Add:

```
base-uri 'none'; frame-ancestors 'none'; form-action 'none'
```

Also send `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and preferably `X-Frame-Options: DENY`.
9. **P1 — r1 §5.5/§6.10, read-only implementation path.**

**Evidence:** `runtimeRoot()` creates and chmods the runtime root and subdirectories: `link/runtime.go:122-192`. The dashboard needs runtime data but claims the observer writes nothing. Calling that helper is therefore a write even when no `$KHALA_HOME` file is created.

**Smallest change:** Add a read-only runtime-root resolver that performs no creation or chmod. Dispatch `dashboard` before normal link logger/singleton setup in `link/main.go:34-42`; use stderr-only logging and no existing helper that creates state.
10. **P2 — r1 §5.1/§5.5, HTTP resource limits.**

**Smallest change:** Set `ReadHeaderTimeout`, `ReadTimeout`, `IdleTimeout`, `MaxHeaderBytes`, bounded response sizes, and a modest concurrency limit. Return `405` with `Allow: GET, HEAD` for all unsupported methods. Apply `no-store` to static, API, and error responses.
11. **P2 — r1 §5.2, automatic local `--with-text`.**

**Conclusion:** Automatically enabling text on an authenticated loopback-only listener is acceptable under the stated model, though the flag name then understates actual behavior.

**Smallest change:** Document the effective rule exactly. Explicit `--with-text` even on loopback would be safer and simpler to reason about, but is not a release blocker.

---

## Q8. Reserved names

The listed sites do not cover every acquisition path, and refusing reserved names as **recipients** is the wrong abstraction for B.

1. **P0 — r1 §3.4, use an acquisition policy rather than scattered checks.**

**Evidence:**
  - CLI identity resolution covers explicit `--as`, `KHALA_SESSION`, and one-line `.khala-session`: `bin/khala:283-315`.
  - `cmd_bind` uses that resolver, but Go `runtime register/bind` independently accepts any `validNode` identity: `link/runtime.go:697-830`.
  - Watcher declaration and `notify --as` call `valid_name` directly: `bin/khala:3245-3376,3800-3910`.
  - `cmd_retire` can create a heartbeat and mind tombstone for any syntactically valid name: `bin/khala:4033-4084`.
  - Hooks and the channel server have independent regex validators: `plugin/hooks/lib.sh:5-8`, `plugin/channel/server.ts:10-30`.

  **Smallest change:** Introduce `valid_session_identity`, `valid_watcher_identity`, and an explicit principal-class policy in both shell and Go. Keep `valid_name` unchanged for node/stream/general syntax. Make Go runtime registration the final enforcement point.
2. **P0 — r1 §3.4, recipient refusal conflicts with B.**

**Evidence:** B’s agreed address is `khala-gateway@<gateway-node>` and session replies must be sent to it. The prior text states this explicitly in `review/gpt-pro-d17-review.md` §3 B2.

**Failure:** If `khala send` rejects every reserved recipient name, B must relax the rule fleet-wide before any session can reply to the gateway.

**Smallest change:** “Reserved” must mean **not claimable by an ordinary session/watcher**, not globally invalid as `To:`. Define per-principal addressability:
  - `conduit`: metadata owner only, neither session-bindable nor generally addressable;
  - `khala-gateway`: gateway-bindable and addressable, never session/watcher-bindable;
  - `khala`: infrastructure sender only;
  - `operator`: envelope type, not necessarily an identity.
3. **P0 — r1 §3.4, missing final gateway name.**

**Evidence:** r1 reserves `gateway`; B specifies `khala-gateway`. Current `valid_name` accepts both.

**Smallest change:** Reserve `khala-gateway` now. Retaining the bare `gateway` reservation is harmless but does not satisfy B. Also reserve `khala`, which current bounce generation uses as an infrastructure sender at `bin/khala:2263-2305`.
4. **P1 — r1 §3.4, watcher owner.**

**Evidence:** `watcher declare --owner` accepts either a bare name or an address and does not apply a principal-class rule: `bin/khala:3830-3855`. A future gateway may legitimately own a watcher even though an ordinary session may not claim the gateway identity.

**Smallest change:** Validate the owner as a reference to an allowed principal class, not with a blanket reserved-name rejection.
5. **P1 — r1 §3.4, runtime `kind`.**

**Evidence:** Runtime registration currently rejects only an empty `kind`; arbitrary values are accepted: `link/runtime.go:717-730`.

**Failure:** A normal caller can self-label as `gateway` while still using the session registration path.

**Smallest change:** Restrict the session command to known session kinds. Give the future gateway a separate registration path/principal type whose verification does not pretend it has a Claude registry/socket.
6. **P1 — r1 §3.4, hooks and channel attach.**

**Evidence:** The hooks resolve `.khala-session` themselves before invoking bind, and the channel child resolves the same file/environment independently: `plugin/hooks/session-start.sh:86-115`, `plugin/channel/server.ts:10-30`. `runtime register-channel` mutates an existing registration without checking its identity class: `link/runtime.go:610-695`.

**Smallest change:** Update duplicate validators for early diagnostics, and make register-channel reject attachment to a principal that is not a session. The authoritative refusal remains in runtime registration.
7. **P1 — r1 §3.4, cleanup paths.**

**Evidence:** `runtime release` and watcher retirement remove or retire existing ownership and should remain capable of cleaning up legacy reserved identities: `link/runtime.go:1027-1125`; `bin/khala:3880-3910`.

**Smallest change:** Apply reserved-name refusal to **creation/acquisition**, not release/retire cleanup. Add migration diagnostics for existing collisions.

---

## Q9. Compatibility with 0.8.2

There is no semantic conflict with the stated 0.8.2 changes if C starts after that merge. The current pinned commit still contains the five-line/one-second implementation, so this judgment is against the stated in-flight delta.

1. **P1 — r1 §5.3/§9.4, parse both watcher formats.**

**Evidence:** Current `read_watcher_marker` requires exactly five newline-terminated lines and rejects a sixth: `bin/khala:383-435`. Old five-line markers can remain replicated after a 0.8.2 rollout because unchanged files are not rewritten and deletion is not propagated.

**Smallest change:** The dashboard parser must accept:
  - five lines → `since: null`;
  - six lines → validate and expose line 6 as `since`.

  Reject every other line count.
2. **P1 — r1 §9.4, 0.8.2’s own mixed-version hazard.**

**Evidence:** An old 0.8.1 reader rejects a six-line `.watcher`.

**Smallest change:** Ensure the 0.8.2 rollout itself updates all readers before any writer begins emitting line 6. C’s serialization after 0.8.2 is correct but does not solve that preceding rollout issue.
3. **P2 — r1 §3.3/§9.4, lock sleep.**

**Evidence:** Current `acquire_lock` sleeps one second at `bin/khala:493-557`; the proposed 0.8.2 change only adjusts retry sleep for non-reconcile callers.

**Conclusion:** No C semantic conflict. Writing the drain stamp while the same brain lock remains held is compatible with the 0.25-second retry.

**Smallest change:** Preserve the 0.8.2 implementation during the serialized merge and add a drain-stamp contention test.
4. **P2 — r1 §3.2, watcher install guard.**

**Evidence:** The Go `.watcher` generation guard reads only the first line through `watcherEpoch`: `link/install.go:516-534`. Adding line 6 does not alter its epoch comparison.

**Smallest change:** None beyond tests with both five- and six-line markers.

---

## Q10. Avoiding a rewrite for B

As written, B would force both an `.ear` format revision and dashboard API reinterpretation. The fixed positional row is the main problem.

1. **P0 — r1 §3.1/§6.1, make identity records extensible now.**

**Evidence:** Adding principal type, operator counts, authentication status, or last-drained-generation to an exact 12-token positional row requires `ears 2` or incompatible parsing. B requires principal classes and authenticated operator telemetry.

**Smallest change:** Change identity records now to bounded key/value tokens with mandatory keys and ignored unknown keys, for example:

```
identity steno principal=session route=socket phase=ready version=2.1.258 \
  pending-operator=0 pending-urgent=0 pending-ordinary=2 pending-info=1 \
  generation=<64hex> first-seen=<epoch> oldest-pending=<epoch> \
  written-rings=3 last-written=<epoch> last-drain=<epoch> \
  last-drained-generation=<64hex-or-dash>
```

Values must use a safe bounded encoding.
2. **P0 — r1 §3.1, add generic node/component fields.**

**Smallest change:** Reserve these v1 records now:

```
written-at <epoch>
state running|stopping
complete yes|no
component conduit <version> <state>
component gateway - absent
capability <name>...
```

Repeated `component` records are preferable to a singular `conduit` field; B can then populate gateway version/health without changing the format.
3. **P0 — r1 §3.1/§9.3, pending classes.**

**Evidence:** B6’s 15-minute threshold applies to authenticated operator/urgent input, while ordinary mail uses 60 minutes and info has no alert. The current `ring-count` cannot distinguish those classes.

**Smallest change:** Publish separate counts for authenticated operator, urgent notice, ordinary ring mail, and info. Unsigned/invalid claimed operator input belongs in ordinary/untrusted, not authenticated operator.
4. **P1 — r1 §5.4, version the HTTP API now.**

**Smallest change:** Use `/api/v1/fleet` and `/api/v1/letter`, or include a mandatory top-level `apiVersion: 1`. Define clients to ignore unknown JSON fields. Reserve `/api/v1/gateway` or a nullable top-level `gateway` object.
5. **P1 — r1 §5.4, reserve B-facing JSON fields.**

**Smallest change:** Add nullable/empty fields now:
  - node: `components`, `capabilities`, `gateway`;
  - identity: `principalType`, `pendingByClass`, `oldestPendingAt`;
  - letter: `type`, `authStatus`, `keyId`, `actor`, `origin`, `conversation`;
  - gateway: inbound/outbound durable queue depth, last update offset, last API success, last 429, topic-map health.

  Keep raw `Origin-Ref`, Telegram IDs, signatures, and content behind the appropriate text/sensitive gate.
6. **P1 — r1 §3.4/§8, reserve the envelope and delivery behavior.**

**Evidence:** Current destination dispatch consumes only `message`, `notice|bounce`, and `ack`: `bin/khala:2244-2366`. `validate_spool_file` only checks filename/`Id`: `bin/khala:2090-2110`. A `Type: operator` object therefore remains indefinitely in `spool/for/<self>` and never reaches an inbox.

**Smallest change:** In 0.9.0, reserve and parse:

```
Envelope-Version
Type: operator
Actor
Origin
Conversation
Origin-Ref
Key-Id
Signature
```

Reject duplicate control headers. Define an unsigned/unknown-key operator object as ordinary untrusted input until 0.10 verification exists, and ensure it is delivered rather than stranded.
7. **P1 — r1 §3.4, reserve `khala-gateway` as addressable system principal.**

**Evidence:** B replies use that address.

**Smallest change:** Add the name and principal/addressability policy in 0.9.0. Do not force B to relax a blanket recipient prohibition later.
8. **P1 — r1 §5/§9.2, reusable dashboard handler.**

**Smallest change:** Implement the read model and HTTP handler independently from listener startup. `khala-link dashboard` supplies the listener/token in 0.9; the resident gateway can mount the same handler in 0.10 without subprocess or API duplication.

---

## Q11. On-demand dashboard

I agree with the on-demand decision.

1. **P2 — r1 §9.2, no resident unit in 0.9.0.**

**Evidence:** B6 notifications are deferred, so 0.9 has no resident alerting responsibility. Adding a third supervised process now would add lifecycle, persistent-authentication, port, and upgrade surface that 0.10 would immediately fold into the gateway.

**Smallest change:** No service unit. Keep the 0.9 command on-demand and loopback-only. Structure its handler/read model for direct embedding by the 0.10 gateway.

The conduit remains resident and produces the snapshots; the dashboard itself need not be resident merely to read them.

---

## Q12. Incorrect factsheet claims

1. **P2 — factsheet basis and stale references.**

**Incorrect claim/reference:** The sheet explicitly says it was prepared at HEAD `e429ac9`, not the requested `2a3f447…`. Numerous `link/config.go` references such as `:494`, `:525`, and `:590-604` do not exist at the target commit; the current file ends around line 116.

**Correct references:** `messageIDPattern` is `link/config.go:16-18`; `loadConfig` is `:32-80`; `validNode`/`validMessageID`/`presenceNode` are `:92-116`.

**Smallest change:** Regenerate all fact-sheet line references against the specified HEAD.
2. **P1 — factsheet introduction, replication scope.**

**Incorrect claim:** “Everything under `$KHALA_HOME` is fleet-replicated.”

**Evidence:** Native installation supports only `spool`, `presence`, `stream`, and `mind`: `link/install.go:35-84`. Fallback exchange moves those same classes: `bin/khala:1960-2030`. Inbox, outbox, archive, config, run, log, join, cursor, delivered log, and other state are not globally replicated.

**Correct claim:** Four object classes are replicated; `$KHALA_HOME` as a whole is not.
3. **P0 — factsheet §4, freshness conclusion.**

**Incorrect claim:** Because native and rsync mtime semantics differ, freshness “must therefore read the epoch inside the file, never file mtime.”

**Evidence:** A remote internal epoch is itself clock-skewed. Native destination mtime is receiver installation time, while rsync preserves source mtime: `link/install.go:146-187,244-250`; `bin/khala:1803-1868`.

**Correct claim:** Use a receiver-local validated `seen-at`; use writer `written-at` for same-writer duration calculations/diagnostics; use generation progress or an explicit bounded-skew assumption for liveness.
4. **P0 — factsheet §4, watcher guard “end to end.”**

**Incorrect claim:** The watcher regression test proves the guard end-to-end.

**Evidence:** `link/install_test.go:411-449` invokes `installer.receive` directly. Fallback rsync at `bin/khala:1803-1868,2018-2030` bypasses the installer entirely.

**Correct claim:** The guard is native-installer-path coverage, not transport-end-to-end coverage.
5. **P2 — factsheet open question 2, reconcile frequency.**

**Incorrect claim:** `.ear` makes reconcile fail “every pass.”

**Evidence:** The `.ear` parse does set `SYNC_FAILED` when `prune_presence` runs: `bin/khala:2702-2753`. The hotfix invokes that prune only on due retention sweeps: `bin/khala:2787-2842`, default every 300 seconds.

**Correct claim:** Every presence invocation fails; reconcile fails on each due presence-retention pass, or every pass only with `retention-interval 0`.
6. **P1 — factsheet §2, pending first-seen.**

**Incorrect claim:** “first-seen is the registration’s `startedAt`.”

**Evidence:** `conduitState` contains no first-seen field: `link/conduit.go:52-59`. Registration `StartedAt` is created when a session registration is created in `link/runtime.go:697-830`; it is unrelated to first observation of a pending generation.

**Correct claim:** Pending-generation first-seen does not exist in the current code.
7. **P2 — factsheet §11, test file count.**

**Incorrect claim:** “Existing Go tests (5 files, 61 tests).”

**Evidence:** The sheet itself lists six files: `config_test.go`, `protocol_test.go`, `install_test.go`, `watch_test.go`, `pump_test.go`, and `conduit_runtime_test.go`. The listed test totals sum to 61.

**Correct claim:** Six files, 61 listed tests.
8. **P2 — factsheet §12, `sanitizePreview` recommendation.**

**Incorrect guidance:** It calls the doorbell’s pre-HTML-escaped `sanitizePreview` the natural helper for browser output.

**Evidence:** The helper replaces `&`, `<`, and `>` with entities at `link/conduit.go:725-742`. Safely rendering that JSON through `textContent` displays the entities literally; rendering it through `innerHTML` invites a fragile, context-dependent security boundary.

**Correct guidance:** Preserve bounded plain text in the API and rely on JSON encoding plus `textContent`.

I found no substantive error in the factsheet’s claims that `.ear` is accepted by the current link, that native installation uses replacement semantics, that rsync preserves mtime, that deletion is not propagated, or that no current drain-generation record exists.

---

## Other findings

1. **P1 — r1 §5.3, Go config lacks `ttl`.**

**Evidence:** Go `loadConfig` handles `self`, `mailbox`, `peer`, and `retain`, but not `ttl`: `link/config.go:32-80`. The shell presence view uses `ttl`, defaulting to 120 seconds, around `bin/khala:5033-5041`.

**Failure:** A Go dashboard that relies only on `loadConfig` cannot reproduce the CLI’s alive/asleep semantics.

**Smallest change:** Add shared TTL parsing with the shell’s bounds/default and test duplicate/invalid semantics.
2. **P0 — r1 §3.1/§3.2, complete parser contract is missing.**

**Evidence:** Unknown-key tolerance is specified, but duplicate mandatory headers, duplicate identities, record ordering, maximum token length, `truncated` placement, and filename/header node mismatch are not.

**Smallest change:** Normatively define:
  - exactly one schema, node, generation, written-at, interval, state, completeness record;
  - node equals basename owner;
  - at most one identity row per name;
  - bounded line/token lengths;
  - `truncated` only once and last;
  - duplicate mandatory records invalidate the file;
  - unknown keyed records are ignored.
3. **P1 — r1 §3.1, snapshot generation authority.**

**Evidence:** The snapshot lives in a replicated mutable presence directory. Fallback currently pulls that directory over local files. Deriving the next generation solely from the existing replicated file makes writer ordering vulnerable to overwrite, corruption, clock rollback, or local deletion.

**Smallest change:** Persist the writer’s last emitted generation in node-local runtime state and take the maximum of that state and any valid owned snapshot. Do not use a remote-replaceable presence file as the sole generation authority.
4. **P1 — r1 §3.1, produce one coherent scan result.**

**Evidence:** Registration verification, lease reclaim/reaping, pending enumeration, and ring state are updated across a conduit scan: `link/conduit.go:336-414`. Independently rereading each source while writing the snapshot can combine a new lease with old registration/pending data.

**Smallest change:** Have one completed scan build an immutable snapshot model and hand that model to the debounced writer. Do not assemble rows through an unrelated second set of filesystem reads.
5. **P1 — r1 §5.3, absent snapshot is not offline.**

**Evidence:** During rollout, an alive 0.8.x conduit produces no `.ear`. Truncation and invalid files also make an identity/node absent for reasons other than being offline.

**Smallest change:** Dashboard node state must distinguish `fresh`, `stopping`, `stale`, `invalid`, `warming`, `legacy/absent`, and `truncated`. Never label absent/legacy as offline or “nobody listening.”
6. **P1 — r1 §3.1/§8, unbounded delivery-journal scanning.**

**Evidence:** Nothing currently deletes `deliveries/<identity>/<instance>/*.json`; both `restoreState` and status scan journal directories: `link/conduit.go:926-983`, `link/runtime.go:1199-1225`.

**Failure:** Reconstructing written counts/last rings from every historical journal on each minute snapshot becomes unbounded.

**Smallest change:** Persist compact per-generation counters/state and add a bounded journal-retention policy. The dashboard should read only current compact state or a bounded latest subset.
7. **P1 — r1 §5.3/§5.5, message and mind size bounds.**

**Evidence:** `messageIDPattern` and several file-derived strings have no API-specific length bounds. Dashboard text mode may read full bodies.

**Smallest change:** Set explicit per-endpoint limits for IDs, headers, mind values, individual bodies, aggregate responses, and number of listed rows. Return a truncation marker rather than allocating unbounded data.
8. **P2 — r1 §3.1, component version semantics.**

**Evidence:** Current `implVersion` is `"0.5.0"` at `link/main.go:22`, while the Khala release is 0.8.1. r1 proposes a separate `linkVersion`, but does not define whether this means release version, protocol implementation version, or ear schema version.

**Smallest change:** Publish them separately, for example `component conduit release=0.9.0 adapter=1 ears=1`, and add a release-build test that the advertised release version is injected correctly.
9. **P2 — r1 §3.1, deterministic mailbox output.**

**Evidence:** Go config accumulates multiple mailbox lines in encounter order: `link/config.go:42-58`.

**Smallest change:** Validate, sort, and deduplicate logical mailbox aliases before snapshot serialization. Config reorder alone should not create semantically different bytes.
10. **P1 — r1 §3.1, local file permissions and durable replacement.**

**Evidence:** r1 states temporary-write plus rename but does not specify mode or directory sync. Existing native installation writes 0600 and syncs the parent: `link/install.go:156-187,244-250`.

**Smallest change:** Require a 0600 temporary file, complete write, file sync, atomic rename, and parent-directory sync. Snapshot loss is recoverable, but the normative writer should match existing install discipline.
