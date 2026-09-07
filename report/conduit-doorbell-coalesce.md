# Conduit doorbell coalescing — 0.9.4 lane report

Date: 2026-09-07  
Branch: `task/doorbell-coalesce`  
Starting base: `ba87284b57dfc6aa79fd8d14b1129e24a9d2dbcb`

## Outcome

The conduit now treats a successfully written frame as the receiving registration process's outstanding wake until a drain stamp proves consumption. A generation change refreshes the next scheduled frame rather than minting a new frame immediately. The first frame, every first frame after consumption, and the first frame for a different `InstanceID` + `PID` + `PIDStart` target remain immediate subject only to `backoff[0]` spacing.

Production rewrite delays are `10m, 20m, 40m, 80m, 160m, 320m`; later gaps remain capped at `320m` (5h20m). An identity that never drains receives at most 9 frames in the first 24 hours (at 0, 10, 30, 70, 150, 310, 630, 950, and 1270 minutes) and at most 5 frames in any later 24-hour period (normally 4 or 5 per day). `KHALA_CONDUIT_TEST_REWRITE_AFTER=<duration>` remains a constant schedule; a comma list supplies the test ladder and its final cap.

Consumption evidence is a valid `run/drained/<identity>` stamp whose `at` is not earlier than the target process's last written frame; equality counts because the stamp has second resolution. The conduit remembers an internal observation token (mtime plus content digest) so a newly written stamp with the same second is still new evidence, while one stamp resets only one outstanding sequence. On restart it reconstructs the sequence from the current registration instance's boot-scoped journals, the unchanged ear sidecar fields, and the drain stamp. Journals do not persist `PID` or `PIDStart`, so a new process that resumes the same instance can inherit that instance's count until the SessionStart drain written by every hook-driven registration; takeover changes the process target in memory and starts at zero because it has no such drain. No sidecar or `ears 1` field was added.

The channel child's `khala_drain` tool uses the same CLI drain: `plugin/channel/server.ts:318-320` calls `run(khala, ['inbox', '--drain'], identity)`. The stamp writer remains only `bin/khala:5664-5665`.

## Properties

| Property | Result | Evidence |
|---|---|---|
| P1 bounded when not draining | PASS | RED commit `4e91883`: `TestConduitBoundsUndrainedGenerationChanges` wrote 44 socket, 43 channel, and 40 channel+socket frames for 40-44 changing generations over 20 first intervals; the new bound was 6. Base H23 wrote 23 frames for 26 letters. After `ef8e0bf`, the Go test passes all three routes and H23 passes with at most 6 frames over 25 first intervals. |
| P2 growing capped schedule | PASS | `TestConduitRewriteSchedule` pins production `10/20/40/80/160/320m`, cap reuse, single-duration compatibility, and comma-list parsing. The first/later-day bounds are calculated above. |
| P3 draining session unchanged | PASS | `TestConduitDrainResetsOutstandingLadder` first records an older stamp, then distinguishes and consumes a second exact 9-field stamp carrying the same `at`; the next generation rings within `backoff[0]`. Shell H13 moves the prior letter to `cur` before stamping; H20 and H19 use the same real drain ordering. |
| P4 drain resets ladder | PASS | `TestConduitDrainResetsOutstandingLadder` reaches the 20ms step, consumes it, then verifies the next successful frame schedules the 10ms first step. |
| P5 restart safe | PASS | `TestConduitRestartPreservesOutstandingLadder` restores two unconsumed writes and their 200ms second-step deadline, then proves no immediate third frame. Shell H8 still passes. Restoration scans only the selected registration instance's journals when state is first needed and retains the original absolute deadline. |
| P6 fresh frames | PASS | H23 compares the final frame's generation with `runtime pending-generation` and checks fresh `pending/notices/urgent/from/subjects/retry`. The unchanged `TestConduitSkipsChangedGenerationImmediatelyBeforeWrite` and `TestConduitPreWriteRecheckAllowsUnchangedGenerationOnce` pass. `retry` is now sourced from successful writes for the current generation, matching its documented meaning rather than counting failed attempts. |
| P7 both paths | PASS | `TestConduitBoundsUndrainedGenerationChanges` covers socket, verified channel, and channel+socket echo. It asserts zero socket echo for verified channel, equal echo counts for channel+socket, and one journal per logical attempt. Full conduit and channel suites pass. |
| P8 hot path | PASS | `TestConduitScanHotPathCost`: 40 identities, 10 pending, one pending identity with 200 journals, 101 measured scans after warm-up. Base median 2.716526ms; pre-r2 median 2.679304ms; r2 median 2.690792ms. R2/base is 0.991 (-0.95%) and r2/pre-r2 is 1.004 (+0.43%), below 1.2. Drain reads and the process comparison occur only inside `maybeRing` for identities with pending ring letters; the instance-scoped journal listing occurs only in initial `restoreState`, never for idle identities or later passes. |
| P9 observability compatible | PASS | `TestConduitCoalescingKeepsEarAlarmSignature` sees the new pending generation with `written-rings=0`, the prior nonzero `last-written`, and `last-drain=0`/older. This is the existing B6 strongest-alarm signature. `.ear` fields, sidecar schema, and status ACK interpretation are unchanged. |
| P10 docs | PASS | The invariant-5 comment now says outstanding-until-drained and generation-only refresh. DESIGN §3.3 has the Korean policy paragraph, ladder/cap, equality rule, reset, and pre-0.9.1 compatibility note. Placement was unambiguous, so no `# AMBIGUOUS` marker was needed. README mentions a single outstanding channel doorbell but does not describe re-ringing; it was intentionally left unchanged. |

## Deliberate non-scope

- Kept socket sender `khala:conduit@<node>` unchanged.
- Did not make frames byte-identical or depend on Claude Code's duplicate filter.
- Kept the `retry:` frame grammar; only corrected its value to count earlier successful writes for that generation.
- Did not change journal retention, `.ear` format, dashboard behavior, `bin/khala`, plugin code, or version strings.
- Takeover is not consumption evidence, but it changes the receiving process; H6 verifies that the new owner receives its own first frame immediately rather than inheriting the old owner's ladder.

## Measurements and verification

| Rig | Base | Pre-r2 | R2 | Gate |
|---|---:|---:|---:|---:|
| Median hot scan, 40 identities / 10 pending / 200 journals | 2.716526ms | 2.679304ms | 2.690792ms | 0.991× base, PASS (≤1.2×) |

All commands used `GOTMPDIR=/NHNHOME/jahn/.cache/go-tmp`, `GOMAXPROCS=16`, `nice -n 19`, and `taskset -c 20-71` where required.

```text
RED Go:
socket: 44 letters -> 44 frames (want <= 6)
channel: 43 letters -> 43 frames (want <= 6)
channel+socket: 40 letters -> 40 frames (want <= 6)
FAIL github.com/Dev-Jahn/khala-network/link

RED shell:
FAIL H23 — 26 letters wrote 23 frames; schedule permits at most 6

go vet ./...: exit 0 (no output)
go test -p 4 ./...:
ok github.com/Dev-Jahn/khala-network/link 6.699s

test/conduit.sh:
ok H13 — an outstanding frame is held; drain consumption makes the next generation ring immediately
ok H23 — 26 changing generations over 25 first intervals stayed within the six-frame ladder bound
ok H8 — restart restores written/failed journal state without an immediate duplicate
RESULT: PASS
Conduit H1-H23 delivery, channel routing, lease, hook, restart, watch, runtime, ears, and dashboard properties passed

test/channel.sh:
RESULT: PASS
Channel E1 opt-in/capability gate plus H21 fast, late-resume, socketpair EOF, re-attach, stale-env, env-fallback, tools, doorbell, and cleanup properties passed

CGO_ENABLED=0 go build -trimpath -o "$HOME/.cache/khala-link-doorbell" .
ELF 64-bit LSB executable, x86-64, statically linked
```

The first full shell run exposed H21 reading the first empty transition snapshot and hard-coding `release=0.9.1`. The exact failure reproduced on the untouched starting base. Commit `79c2250` makes H21 wait for its identity row and validates the release token structurally; no product version was changed. The subsequent full suite passed.

## Rider r2 — process-bound outstanding state

### RED evidence

Commit `31a4c27` made H6 discriminating by setting H4's conduit rewrite interval to 30 seconds while retaining H6's two-second wait, and added `TestConduitOutstandingStateDoesNotCrossProcesses` with two registrations for one identity. On `96c41f4` both layers failed because the claimant inherited the owner's outstanding count:

```text
RED Go:
=== RUN   TestConduitOutstandingStateDoesNotCrossProcesses
    conduit_runtime_test.go:500: new process received 0 frames; want its first frame immediately
--- FAIL: TestConduitOutstandingStateDoesNotCrossProcesses (0.11s)
FAIL
FAIL github.com/Dev-Jahn/khala-network/link 0.111s

RED shell:
ok H4 — only the lease owner is rung; a second SessionStart warns and drains nothing
ok H5 — non-interactive registration cannot acquire a lease without opt-in
FAIL H6 — new owner was not rung after takeover
```

### Fix and residual

Commit `9e7b48e` binds in-memory outstanding state to `InstanceID` + `PID` + `PIDStart`. A target change clears the old target's outstanding count and schedule anchor, resets delivery attempts/failures, and schedules the new target immediately subject only to `backoff[0]`; its first successful write sets count 1 and schedules the first rewrite step. Identity-wide `.ear` values remain unchanged. A separate runtime-only `outstandingWritten` anchor prevents a prior instance's identity-wide `last-written` value from affecting the selected process's consumption check or ladder.

`restoreState` again reads only `deliveries/<identity>/<instance>/`, and the Go test proves that claimant restoration counts one claimant journal rather than the owner's plus the claimant's. The unavoidable restart residual is documented rather than hidden: journals do not contain `PID`/`PIDStart`, so a new process reusing the same instance can inherit that instance's count until its SessionStart drain; every hook-driven registration performs that drain, while takeover is protected by the live process-key comparison because it performs no drain.

### P8 and verification

`TestConduitScanHotPathCost` measured 2.690792ms after r2, versus 2.716526ms on the base and 2.679304ms before r2. That is 0.991× base and 1.004× pre-r2. The tuple comparison runs only for pending ring identities inside `maybeRing`; idle scans gained no work, and restoration now lists one instance directory instead of every instance under the identity.

All commands used `GOTMPDIR=/NHNHOME/jahn/.cache/go-tmp`, `GOMAXPROCS=16`, `nice -n 19`, and `taskset -c 20-71` where required.

```text
R2 targeted Go:
--- PASS: TestConduitRestartPreservesOutstandingLadder
--- PASS: TestConduitOutstandingStateDoesNotCrossProcesses
--- PASS: TestEarSidecarSurvivesRestartAndCountsOnlyWritten
PASS

R2 P8:
median scan: 2.690792ms (40 identities, 10 pending, one with 200 journals)
PASS

go vet ./...: exit 0 (no output)
go test -p 4 ./...:
ok github.com/Dev-Jahn/khala-network/link 6.731s

CGO_ENABLED=0 go build -trimpath -o "$HOME/.cache/khala-link-doorbell" .:
ELF 64-bit LSB executable, x86-64, statically linked

test/conduit.sh:
ok H6 — takeover bumps only the epoch, reroutes delivery, and sends no signal
ok H8 — restart restores written/failed journal state without an immediate duplicate
RESULT: PASS
Conduit H1-H23 delivery, channel routing, lease, hook, restart, watch, runtime, ears, and dashboard properties passed

test/channel.sh:
RESULT: PASS
Channel E1 opt-in/capability gate plus H21 fast, late-resume, socketpair EOF, re-attach, stale-env, env-fallback, tools, doorbell, and cleanup properties passed
```
