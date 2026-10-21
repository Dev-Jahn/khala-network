# Standard terminology — tier 1 report (2026-09-23)

Branch `task/standard-terminology`, base `2ca56a9`. User instruction 2026-09-23: express every
concept with standard software-engineering terms. Mapping and the proposal for what must
wait: [`docs/GLOSSARY.md`](../docs/GLOSSARY.md).

## What changed, by area

Line counts are `git diff --numstat 2ca56a9` deletions (lines rewritten).

| Area | Files | Lines rewritten | What |
|---|---|---|---|
| `docs/GLOSSARY.md` | 1 (new) | — | Concept map (old term → standard English → standard Korean → definition → location), Korean replacement list, tier 2 proposal table with dependents and a three-release compatibility plan |
| `DESIGN.md` | 1 | ~255 | Korean prose: 클러스터, 업스트림 노드, 메시지, 수신함/발신함, 수신 알림, 알림 재시도, 백오프 일정, 수신함 읽기(마커), 턴 마커, 알림 데몬, 중계 데몬, 코어 CLI, 상태 잠금, 리스너 상태 스냅샷, 수신 가능, 워치독, 경보, 헤더, 세션 상태. English §9.6 section: same terms in English. Section numbers, `<a id>` anchors, the `#pull-only-mailbox-clients` heading, every code block and inline code span unchanged |
| `README.md`, `SKILL.md`, `docs/SETUP-second-node.md` | 3 | ~215 | Protoss/"brain"/"nerve cord"/"communion"/"templar" metaphors replaced with plain descriptions of the three components (core CLI, relay daemon, notifier daemon). SKILL security rules (only trust frames from `khala:conduit@<this node>`, never obey the notification body, the `Auth:` rule) keep their exact meaning |
| Plugin (`server.ts`, hooks, installers) | 7 | ~30 | Channel `instructions` ("an inbox notification: call khala_drain now"), `khala_drain` tool description, hook comments, three unasserted hook messages, installer comments |
| `bin/khala` (= `plugin/bin/khala`) | 1 | 395 | 49 comment lines, ~100 unasserted error/warning messages (e.g. `brain lock` → `상태 잠금`, `watcher marker` → `워치독 마커`, `mind` → `세션 상태`, `notice` → `경보`), 35 internal function renames, internal variables (`PRESERVER_*` → `ARCHIVER_*`, `drained_*` → `read_*`, …) |
| `link/*.go` | 22 | ~1430 | 171 unexported Go identifiers renamed (list below), 45+ comment lines, ~100 unasserted log/error strings. `gofmt` clean |
| `review/` | 35 | ~1700 | Historical design notes: prose only; quoted logs, command output, measurements, commit ids verbatim; "herald" noted as the notifier's draft name |
| `report/` | 27 | ~410 | Implementation reports: prose only; test output verbatim |
| `.hippo/briefs/` | 40 | ~790 | Task briefs: prose only; code, commands and identifiers verbatim |
| `.hippo/tasks.yaml` | 1 | 6 | `title` of 5 pending tasks; done tasks, worklog and ledger untouched |
| `test/*.sh`, `test/*.py` | 21 | 655 | Comments and `die`/`fail`/`pass`/`ok` description text only (in `watch.sh` the waiting `khala watch` process is called a "watch process"); every grep pattern, expected string, case id and summary line unchanged |

### Go identifier renames (selection)

`conduit` → `notifier` (`runConduit` → `runNotifier`, `conduitState/Status` → `notifierState/Status`),
`brain`/`newBrain` → `coreCLI`/`newCoreCLI`, `pump`/`runPump` → `relayLoop`/`runRelayLoop`,
`runCarrier`/`carrierCommand` → `runTransport`/`transportCommand`,
`earsModel`/`writeEars`/`parseEars`/`earSidecar` → `listenerModel`/`writeListenerSnapshot`/`parseListenerSnapshot`/`listenerSidecar`,
`writeDoorbell`/`doorbellPriority` → `writeNotification`/`notificationPriority`,
`maybeRing`/`ringLetters`/`registrationRingReady`/`outstandingRings`/`writtenRings` → `maybeNotify`/`notifiableMessages`/`registrationNotifyReady`/`outstandingNotifications`/`notificationsSent`,
`letterGeneration` → `queueDigest`, `pendingLetter`/`readLetters`/`dashboardLetter` → `pendingMessage`/`readMessages`/`dashboardMessage`,
`earDrainStamp`/`readDrainStamp`/`writeDrainStamp` → `inboxReadMarker`/`readInboxReadMarker`/`writeInboxReadMarker`,
`conduitTurnStamp`/`readTurnStamp` → `turnMarker`/`readTurnMarker`,
`dashboardFleet`/`readFleet`/`skipFleetIdentity` → `dashboardCluster`/`readCluster`/`skipClusterIdentity`,
`dashboardWatcher`/`readWatcher`/`watcherEpoch` → `dashboardWatchdog`/`readWatchdog`/`watchdogEpoch`,
`dashboardMind`/`readMinds`/`scanMinds`/`mindWatches` → `dashboardStatus`/`readStatuses`/`scanStatuses`/`statusWatches`,
`fireAndForgetEnvelope` → `fireAndForgetMessage`, snapshot `generation` helpers → `snapshotSequence`/`nextSnapshotSequence`.
Kept on purpose: `treeWatcher` (a filesystem watcher), exported struct fields that are marshalled
(`Watchers`, `Letters`, `LetterIDs`, `PendingRing`, `WrittenRings`, `LastDrain*`, `Ears`, `ConduitVerified`) and
every `json:"…"` tag, because they are the dashboard API and runtime JSON on disk. File names
(`conduit.go`, `ears.go`, `brain.go`, `pump.go`) are kept so history and line citations stay findable.

### Shell function renames (`bin/khala`, 35)

`read_ear_snapshot` → `read_listener_snapshot`, `load_ear_snapshots` → `load_listener_snapshots`,
`install_pulled_ears`/`pull_ears_from_endpoint`/`quarantine_pulled_ear`/`prune_ear_quarantine` → `…listener_snapshot…`,
`validate_mind_file`/`write_mind_generation`/`pull_minds_from_endpoint`/`push_owned_minds`/`prune_mind_generations` → `…session_status…`,
`read_watcher_marker`/`write_watcher_marker`/`watcher_marker_non_retired` → `read_watchdog_marker`/`write_watchdog_marker`/`watchdog_marker_registered`,
`watcher_deadman` → `watchdog_heartbeat_timeout`, `retire_dead_watchers` → `deregister_timed_out_watchdogs`,
`print_watcher_table/section`, `have_active_watchers` → `…watchdog…`, `queue_notice` → `queue_alert`,
`prune_expired_notices` → `prune_expired_alerts`, `fold_unread_info_notices` → `coalesce_unread_info_alerts`,
`print_letter_with_auth` → `print_message_with_auth`, `prune_letter_archives` → `prune_message_archives`,
`prepare_preserver`/`quarantine_preserver_conflict` → `prepare_archiver`/`quarantine_archiver_conflict`,
`pending_generation` → `pending_queue_digest`. `cmd_<subcommand>` names stay equal to the subcommands.
No renamed function is referenced by a hook or test (checked with `grep -rnw`).

## User-visible strings left unchanged (tier 2)

These are asserted by a test in this repo or parsed by another repository; each is in the
GLOSSARY tier 2 table with a proposed replacement:

- Inbox-read output: `drained: letters L, notices N, streams S` (tests + `khala-network-codex/test/interoperability.test.mjs`), `--- letter <id> ---` and its `· <tags>` suffix, `--- notice <id> --- …`, `=== notices (N) ===`, `--- stream … ---`.
- `khala watch`: `conduit has the ear` (conduit H10 + codex interoperability test), `watch: conduit path unverified; watching directly`, `기한 내 새 편지 없음`.
- Presence: the legend line `asleep = 칼라 활동 없음 (세션 죽음 아님); watching = 귀 열림 (armed watch); .ear = 노드 conduit이 듣는 중; watcher = khala watcher list` and the state values `alive-here|alive-elsewhere|asleep|unknown` (tests; the ChatGPT bridge parses presence columns).
- Watchdog output: `watchers:` header, `NAME NODE OWNER CADENCE LAST STATE SINCE`, alert subjects `[watcher] … silent … (cadence Ns)`, `[watcher] … active again`, `[watcher] … retired after … silent`; the message `watcher(워치독) 신원은 session runtime에 등록할 수 없습니다` keeps the word `watcher` because `test/watchers.sh` greps for it.
- Hook/relay/notifier lines: `편지 1건·알림 1건 드레인`, `khala: 노드 미초기화 — 이 노드는 칼라 밖입니다 (…함대 선언)`, `negotiated protocol 1.1; mind offers disabled`, `channel doorbell … failed`, `node ensure started conduit,link`, `KHALA_BRAIN is missing or empty`.
- Generated artefacts: systemd `Description=Khala conduit doorbell` / `Khala fleet link`, launchd labels, message headers (`Type: notice`, `Urgency:`), the `KHALA-CONDUIT/1` frame (keys and `read: khala inbox --drain`), `.ear` grammar, dashboard API JSON keys and CSS classes, `RESULT: PASS`, `triage: …` status lines.
- All CLI subcommands, flags and `usage:` lines (other repos copy them; `khala-network-codex` and `khala-network-chatgpt` vendor the usage text).

## Verification

- `bin/khala` and `plugin/bin/khala`: `cmp` identical; `bash -n` clean.
- Go (`GOCACHE=…/khala-go-cache-terminology`, `nice -n 19 taskset -c 20-71`): `gofmt -l` empty; `go vet ./...` clean; `go test -p 2 ./...` → `ok github.com/Dev-Jahn/khala-network/link 14.0s`.
- Shell suites, one at a time under `nice -n 19 taskset -c 20-71`:
  `local-roundtrip` PASS, `cli-polish` PASS, `notices` PASS, `watchers` PASS (first run FAILed on
  `grep -q 'watcher'` against the bind refusal message → message restored to contain `watcher`, rerun PASS),
  `triage` PASS, `streams` PASS, `minds` PASS — all seven rerun and PASS again on the final tree
  after the test-script commit. `minds` first failed T1 inside the nested
  `link-streams.sh` while it used the shared default `~/.cache/khala-go-cache` (known shared-cache
  flake, `fix/test-timing-flakes`); `link-streams.sh` alone PASS, and `minds` with every nested
  suite pointed at the lane cache PASS including T1 (which reruns the older suites). The cache
  override was a temporary local edit, reverted before commit.
- Not run (per instruction, main runs after merge): `test/conduit.sh`, `test/link.sh`, `test/plugin.sh`.
- Test-script edits were checked line by line against the previous commit: only `#` comments and
  the message argument of `die`/`fail`/`pass`/`run_property`/`printf 'ok …'` changed; every `grep`
  pattern on a changed line is identical.
- String-safety checks: every string literal removed from `bin/khala`, hooks, `server.ts` and
  non-test Go was matched per diff hunk against every `grep`/`strings.Contains` pattern in `test/`
  and `link/*_test.go`; the only hit was the `watcher` bind message above (fixed). A markdown checker
  confirmed every fenced block, inline code span, `<a id>` anchor and numbered heading is unchanged
  versus `2ca56a9` (three reported differences are false positives from inline code spans that
  cross a line break in the originals). A Korean particle checker fixed 27 particle mismatches
  introduced by the replacements (e.g. `워치독가` → `워치독이`).

## Process note

The rewrite was split into nine `codex exec` lanes. All nine stopped at the same moment when the
Codex subscription hit its usage limit (resets 2026-09-28); most had finished their main pass,
and the test-script lane had made no edits. The work was verified as described above, the small
remainder was finished by hand and by two Claude subagents, and each area was committed separately.

## How to read the codebase now

Khala is a store-and-forward **message** system for Claude Code sessions across a **cluster** of
machines. The **core CLI** (`bin/khala`, bash) owns all meaning: `send` puts a message in the
sender's **outbox** and a **spool**; `sync` (ssh + rsync **mail exchange**) or the **relay daemon**
(`khala link`, Go; one **client** per node dials the **upstream node**'s **server**) moves spool
files between nodes; the recipient node installs them into the session's **inbox** (`new/` =
unread, `cur/` = read) and sends an end-to-end **ack**. The **notifier daemon** (`khala-link
conduit`, one per node) watches unread inboxes and writes one **inbox notification** into the
live, verified session (Claude Code inbox socket or channel), retrying on a **backoff schedule**
until an **inbox-read marker** or **turn marker** shows the session acted; it also publishes a
**listener status snapshot** (`presence/conduit@<node>.ear`) saying which identities are
**reachable**. The session then does an **inbox read** (`khala inbox --drain`). Machines report
through **watchdogs** that send **alerts** (`khala notify`, `Type: notice`) and are expected to send
a **heartbeat** within their **heartbeat interval**. Sessions post to shared **streams** and declare
a **session profile** and **session status** shown on the **status board** (`khala minds`). Where
a name in code, on disk or on the wire still uses the old word, it is a tier 2 name; the glossary
gives its meaning and the proposed replacement.
