# khala 0.8.1 fact sheet — for the 0.9.0 read-only fleet dashboard + per-node "ears" snapshot

Repo `/NHNHOME/WORKSPACE/0526040002_A1/jahn/workspace/khala-network`, git HEAD `e429ac9`, `KHALA_VERSION=0.8.1` (`bin/khala:28`).
Two programs: the bash brain/CLI `bin/khala` (5158 lines) and the Go binary `khala-link` (`link/`, one `package main` with subcommands).
Everything under `$KHALA_HOME` (default `$HOME/.khala`, `bin/khala:6-18`, `link/main.go:226-238`) is fleet-replicated; the *runtime dir* is node-local and never replicated.

---

## 1. Runtime dir (node-local, not replicated)

**Root selection** — `runtimeRoot()`, `link/runtime.go:122-161`:
- `$KHALA_RUNTIME_DIR` if set (`link/runtime.go:124-125`);
- else Linux: `/run/user/<euid>/khala` when `/run/user/<euid>` exists, is a non-symlink dir owned by euid (`link/runtime.go:126-136`); otherwise `/tmp/khala-<euid>` (`link/runtime.go:137-139`);
- else darwin: `$TMPDIR/khala-<euid>` (`link/runtime.go:140-145`); else `/tmp/khala-<euid>` (`link/runtime.go:146-148`).
- Root and the four subdirs `sessions/ identities/ deliveries/ channels/` are created and hardened by `secureDirectory` (`link/runtime.go:155-159`, `163-192`): refuses symlinks, refuses non-dirs, refuses foreign uid, chmods to 0700.
- Measured live on this node: `/run/user/2980/khala` with exactly `channels/ conduit.lock conduit.status.json deliveries/ identities/ sessions/`.
- `khala-link runtime root` prints it (`link/runtime.go:541-551`).

**Files written there**

| Path | Format | Writer | Reader | Deleter |
|---|---|---|---|---|
| `sessions/<instanceId>.json` | JSON `sessionRegistration` | `writeRegistration`/`mutateRegistration` (`link/runtime.go:518-539`), called from `runtime register`/`bind` (`:811`), `register-channel` (`:647`), `native-warning` (`:1334`), conduit verify (`link/conduit.go:366`) & native status (`link/conduit.go:993`) | `loadRegistrations` (`link/runtime.go:491-512`) | `runtime release` (`link/runtime.go:1089`), conduit reaper (`link/conduit.go:657`) |
| `sessions/.sessions.lock` | one line `{"bootId":"…"}\n` | `withRuntimeLock` (`link/runtime.go:914-944`) via `withRegistrationLock` (`:514-516`) | same | never |
| `identities/<identity>.lease` | JSON `identityLease` | `claimLease` (`link/runtime.go:1001`), release (`:1116`), `healLease` (`link/conduit.go:525`) | `readJSON` at `link/runtime.go:953`, `:1164`, `:1251`; `link/conduit.go:403`, `:507`, `:557`, `:617` | never removed; only mutated to `state:"released"` |
| `identities/.leases.lock` | `{"bootId":"…"}\n` | `withRuntimeLock` (`link/runtime.go:951`, `:1097`; `link/conduit.go:514`) | same | never |
| `deliveries/<identity>/<instanceId>/<attemptId>.json` | JSON `deliveryJournal` | conduit `maybeRing` (`link/conduit.go:894-901`) | `latestDeliveryJournal` (`link/runtime.go:1201-1225`), `restoreState` (`link/conduit.go:926-983`) | **nothing deletes them** — see Open questions |
| `channels/<instanceId>.sock` | Unix socket | the plugin channel MCP child (outside Go; path enforced at `link/runtime.go:671-673`) | conduit `verifyChannelSocket` (`link/conduit.go:1087-1117`), `writeChannelDoorbell` (`link/conduit.go:1235`) | the channel child |
| `conduit.status.json` | JSON `conduitStatus` | `runConduit` on start, `writeAtomicJSON` (`link/conduit.go:140-146`) | `runtime daemon-status` (`link/runtime.go:1290`), conduit's own liveness pre-check (`link/conduit.go:127-135`) | never |
| `conduit.lock` | flock'd file whose body is `{"bootId":"…"}\n` | `acquireConduitSingleton` (`link/conduit.go:175-204`) | same | never (stable inode by design, comment `link/conduit.go:188-190`) |
| `.khala-write-*` | transient | `writeAtomicJSON` temp (`link/runtime.go:255`) | — | renamed away or removed (`:264`) |

**`sessionRegistration`** — `link/runtime.go:23-46`:
`bootId, instanceId, identity, pid, pidStart, claudeSessionId, socketPath?, channelSocket?, channelPID?, channelPIDStart?, channelVerified?, kind, receiveOptIn, phase, ccVersion, startedAt, leaseEpoch, conduitVerified, verifiedAt?, nativeStatus?, nativeFailureCount?, nativeWarningShown?`
Live sample: `{"bootId":"1538c119-…","instanceId":"107a48b1-…","identity":"steno","pid":1177841,"pidStart":"1538c119-…:969038246","claudeSessionId":"756ab6c2-…","socketPath":"/tmp/cc-socks/1177841.sock","kind":"interactive","receiveOptIn":false,"phase":"ready","ccVersion":"2.1.258","startedAt":"2026-09-02T07:30:40.381279421Z","leaseEpoch":2,"conduitVerified":true,"verifiedAt":"2026-09-03T02:10:10.072067716Z"}`

**`identityLease`** — `link/runtime.go:48-58`: `bootId, identity, instanceId, epoch, pid, pidStart, claudeSessionId, claimedAt, state` (`state` ∈ `owned` | `released`).

**`conduitStatus`** — `link/runtime.go:60-67`: `bootId, pid, pidStart, runtime, adapter, startedAt`. `adapter` is the constant `"1"` (`link/conduit.go:28`, set at `:142`).

**`deliveryJournal`** — `link/conduit.go:30-45`: `bootId, identity, instanceId, generation, attemptId, attemptIndex, attemptedAt, letterIds[], status, peerStatus, ccVersion, via?, channelError?, error?`. `status` ∈ `written` | `failed` (`link/conduit.go:835`, `:891`); `via` ∈ `socket` | `channel` | `channel+socket` (`:859`, `:865`, `:880`, `:884`); `peerStatus` is always the literal `"unknown"` (`:825`) — never updated.

**`bin/khala status`** — `cmd_status` (`bin/khala:4282-4290`) just execs `khala-link runtime status`. That prints (`link/runtime.go:1159-1197`):
- line 1: `runtime: <root>` (`:1159`);
- header `IDENTITY PENDING OWNER INSTANCE PHASE SOCKET CHANNEL CC_VERSION ADAPTER LAST_ATTEMPT LAST_STATUS ACK NATIVE` (tab-separated, `:1160`).
- Row sources: identity set = union of registration identities and `identities/*.lease` basenames (`:1143-1152`), sorted; `PENDING` = count of regular files in `$KHALA_HOME/inbox/<identity>/new` (`:1162`, `countRegularFiles` `:1350-1361`); `OWNER` = `yes` iff lease bootId matches, instanceId non-empty and state `owned` (`:1194`); `INSTANCE` = `lease.instanceId` or `-`; `PHASE` = registration `phase`; `SOCKET`/`CHANNEL` = `yes` if the path field is non-empty else `-` (`:1166-1173`) — **the paths themselves are not printed**; `CC_VERSION` = `reg.ccVersion`; `ADAPTER` = `socket-v1` iff `reg.ConduitVerified` else `-` (`:1175-1178`); `LAST_ATTEMPT`/`LAST_STATUS` from the newest delivery journal for that identity+instance (`:1180-1182`); `ACK` = `consumed` iff every `letterIds[i]` exists in `inbox/<identity>/cur/` (`:1183-1191`); `NATIVE` = `reg.nativeStatus` or `-`.
- **`conduit.status.json` itself is NOT read by `khala status`.** It is only read by `runtime daemon-status` (`link/runtime.go:1277-1297`), which prints nothing and exits 0 iff bootId matches and the pid/pidStart is alive; `khala node ensure` uses that as its "is the conduit up" probe (`bin/khala:4394`).

## 2. Conduit registration verification

**Loop cadence** — `conduit.run` (`link/conduit.go:254-308`): initial `scan()`, then a `time.Ticker` at `c.scanEvery` = **1 second** by default (`link/conduit.go:154`, overridable with `KHALA_CONDUIT_TEST_SCAN_INTERVAL`), plus a 200 ms-debounced rescan on any fsnotify event (`:276-280`, `:298-305`; dotfile events ignored `:302`), plus a full rescan on watcher error (`:291-297`). Watched dirs: `$KHALA_HOME/inbox`, `<runtime>/sessions`, `<runtime>/identities`, and every `inbox/<node>/new` (`refreshWatches`, `link/conduit.go:310-334`).

**"Verified"** — `verifyRegistration` (`link/conduit.go:442-494`). It first re-resolves pid/socket/ccVersion/pidStart from the Claude Code registry (`~/.claude/sessions/*.json`, or `$KHALA_CLAUDE_SESSIONS_DIR`; `loadClaudeRegistries` `link/runtime.go:421-459`, `registryDirectory` `:386-395`). Then the ordered gate (each failure yields a `reason` string):
1. `resolved.BootID != c.bootID` → `"boot id mismatch"`;
2. `Phase != "ready"` → `"phase is not ready"`;
3. `Kind != "interactive" && !ReceiveOptIn` → `"non-interactive registration lacks opt-in"`;
4. `PID <= 1` or `processAliveWithStart` fails → `"pid/start mismatch"` (pid start is `bootID + ":" + /proc/<pid>/stat field 20`, `link/runtime.go:309-338`);
5. `ClaudeSessionID == ""` → `"Claude session id is empty"`;
6. `SocketPath == ""` → `"socket is not bound"`;
7. `Lstat(SocketPath)` must succeed and be a Unix socket → `"socket is missing or not a Unix socket"`; uid must be euid → `"socket uid mismatch"`;
8. a matching Claude registry entry with identical pid **and** socket must exist → `"Claude registry pid/socket mismatch"`; if the registry carries a session id it must match → `"Claude registry session id mismatch"`.
On a state change it sets `ConduitVerified` and stamps/clears `VerifiedAt` (`:485-492`). **`ChannelSocket` is NOT part of `verified`** — it is checked separately at ring time (`verifyChannelSocket`, `link/conduit.go:1087-1117`).

**Ring-time gate** (stricter, `link/conduit.go:830-832`): `reg.ConduitVerified && reg.Phase=="ready" && lease.InstanceID==reg.InstanceID && lease.Epoch>0 && lease.Epoch==reg.LeaseEpoch && lease.PID==reg.PID && lease.PIDStart==reg.PIDStart && lease.ClaudeSessionID==reg.ClaudeSessionID`. Failing it writes a `failed` journal with error `"registration is not ready and conduit-verified"`.

**Verification logging is edge-triggered** — `logVerification` (`link/conduit.go:424-440`) logs only on transition or reason change; `verificationReasons map[string]string` in memory is the only place the *current* unverified reason lives (`link/conduit.go:87`, pruned at `:416-422`). **It is never written to disk** — this is the single biggest gap for an "ears" snapshot.

**Dead/unregistered detection & removal**
- A dead registration is reaped only after `deadRegistrationReapAfter = 10 * time.Minute` since `StartedAt`, and only if it does not own its lease (`deadRegistrationExpired` `link/conduit.go:605-613`; `reapDeadRegistrations` `:627-673`; `registrationOwnsLease` `:615-625`). It deletes `sessions/<instance>.json`.
- `reclaimLeases` (`link/conduit.go:543-603`) re-points a dead-owner lease to the newest verified eligible registration for that identity (sorted by `StartedAt` desc, tie-break instanceId asc) and bumps the epoch.
- `healLease` (`link/conduit.go:501-541`) copies pid/pidStart into a lease that recorded none (the `claude --resume` race).
- `runtime release` (`link/runtime.go:1027-1125`) — the SessionEnd hook path — deletes the registration file and flips the lease to `released` (keeps `epoch`).
- `leaseOwnerLive` (`link/runtime.go:1006-1025`) treats a registration with `PID<=1` and `StartedAt` within 30 s as still live.

**Per-identity facts held in memory** — `conduitState`, `link/conduit.go:52-59`:
```go
type conduitState struct {
	generation   string
	attemptIndex int
	lastAttempt  time.Time
	nextAttempt  time.Time
	failures     int
	echoLogged   bool
}
```
Held in `conduit.states map[string]*conduitState` keyed by identity (`link/conduit.go:86`), deleted when nothing is pending (`:397-399`, `:786-788`). Rebuilt after a restart from the delivery journals by `restoreState` (`link/conduit.go:926-983`).

**Per-identity facts on disk**: pending count is *derived* (count of `inbox/<id>/new`, `link/conduit.go:675-723`); generation / attemptIndex / attemptedAt / status / letterIds / via / channelError / ccVersion / error live in `deliveries/…/<attemptId>.json`; first-seen is the registration's `startedAt`; verified-at is `verifiedAt`; phase/kind/ccVersion/receiveOptIn/socketPath/channelSocket/channelVerified/nativeStatus/nativeFailureCount live in the registration. The channel-vs-socket **route decision** is not stored as a field — it is recomputed per ring (`link/conduit.go:853-886`) and only visible after the fact as `journal.via`.

The full conduit struct (`link/conduit.go:76-90`):
```go
type conduit struct {
	home, runtime, bootID, self string
	logger *log.Logger
	scanEvery time.Duration
	backoff []time.Duration
	degradeAt int
	statesMu sync.Mutex
	states map[string]*conduitState
	verificationReasons map[string]string
	watcher *fsnotify.Watcher
	watchedDir map[string]struct{}
}
```
Backoff (`conduitBackoff`, `link/conduit.go:231-252`): `100ms, 300ms, 1s, 3s, 10s, 30s`. `degradeAt = 3` (`:155`): after 3 consecutive failures `nativeStatus` becomes `"native-degraded"` (`updateNativeStatus`, `:985-1003`). A **written** doorbell is not re-rung for `conduitRewrittenAfter()` = **10 minutes** (`link/conduit.go:222-229`, applied `:911`).

## 3. Doorbell frame

**Socket frame** — `conduit.frame` (`link/conduit.go:1009-1026`). The JSON envelope is
`{"type":"user","message":{"role":"user","content":"<text>"},"from":"khala:conduit@<self>","priority":<next|later>,"msg_id":"<generation>:<attemptId>"}`
written newline-terminated to `reg.SocketPath` with a 250 ms dial + 250 ms write deadline (`writeDoorbell`, `link/conduit.go:1211-1233`). `content` (truncated to 8192 bytes at a UTF-8 boundary, `:1015-1020`) is exactly:

```
KHALA-CONDUIT/1
recipient: <identity>@<self>
pending: <mail>
notices: <notices>
urgent: <urgent>
streams: <streamPending>
from: <comma-joined senders>
subjects: <semicolon-joined subjects>
generation: <generation>
attempt: <attemptId>
retry: <retry>
read: khala inbox --drain
```

- `generation` = `letterGeneration(letters)` — SHA-256 hex over the sorted ring-set letter ids each NUL-terminated (`link/conduit.go:744-758`). The ring set excludes non-urgent notices (`ringLetters`, `:760-768`).
- `attempt` = a fresh UUIDv4 per attempt (`newUUID`, `link/runtime.go:234-243`; minted `link/conduit.go:817`), also the journal filename.
- `retry` = `attemptIndex-1`, i.e. the number of earlier attempts already written for this same generation, 0 on the first ring (`link/conduit.go:839` passes `attemptIndex-1`; rationale comment `:1005-1008`). `attemptIndex` resets to 0 whenever the generation changes (`:801`) and increments per attempt (`:813`).
- `pending`/`notices`/`urgent` from `letterCounts` (`:770-782`); `streams` from `pendingStreams` (`:1140-1197`) = unread joined-stream entries past the join epoch and past the cursor.
- `from`/`subjects` from `doorbellDisplay` (`:1028-1051`), max 8 each, urgent notices prefixed `U · `, values HTML-escaped and newline-stripped by `sanitizePreview` (`:725-742`).
- `priority` = `"next"` unless **every** ring letter carries `Priority: later`, then `"later"` (`doorbellPriority`, `:1119-1138`).

**Channel frame** (when `reg.ChannelSocket != ""`) — `channelRequest` (`link/conduit.go:1053-1085`): `{"v":1,"content":"<lines>","meta":{from,subject,pending,notices,urgent,generation,attempt,retry,user[,later]}}`; response must be a ≤4096-byte JSON line `{"ok":bool,"error":string}` (`writeChannelDoorbell`, `:1235-1274`). Route order: verify channel → write channel; on channel error fall back to the socket and record `channelError` (`:853-886`). If the channel is unverified the socket ring is echoed too (`via:"channel+socket"`).

**Pre-write re-check**: after building the frame the conduit re-reads the inbox and aborts if the generation changed (`link/conduit.go:843-852`) — no journal is written in that case.

## 4. Presence replication

**Accepted suffixes** — `presenceNode` (`link/config.go:590-604`) strips exactly one of `.watching`, `.watcher`, `.ear` (`link/config.go:592`) then requires `name@node` with a valid node and a valid basename. So **`.ear` is already accepted by the link today; `.ears` is not.** Tests: `link/config_test.go:59-68` (`"steno@alpha.ear"`), `link/install_test.go:125-144` (`.watching`/`.watcher`/`.ear` all install on both dial and serve). No producer or consumer of `.ear` exists anywhere else in the tree — `bin/khala`, the hooks and the conduit never write or read it (grep over `link/ bin/khala plugin/ test/` finds only the three test/config sites).

**Install rules for class `presence`** — `installer.destination` (`link/install.go:51-59`): basename owner must equal the offer's node; `serve` accepts presence only from the connected spoke; destination is always `$KHALA_HOME/presence/<basename>`.
`installer.receive` (`link/install.go:228-251`) treats presence as a **mutable lease**: it is the one class that is atomically *replaced* rather than no-clobber installed (rationale comment `link/install.go:223-227`). Sequence: rename tmp → dest, then `syncDir` the parent.

- **`.watcher` epoch regression guard** (`link/install.go:233-243`): if the incoming bytes' first line parses as an epoch (`watcherEpoch`, `:516-534` — accepts a bare integer or `retired <epoch>`, ≤18 chars, non-negative) and it is **strictly less** than the existing file's epoch, the incoming copy is dropped and logged `"stale watcher declaration ignored"`. A `retired <epoch>` tombstone with a **higher** epoch therefore installs and cannot be revived by an older active copy — asserted end to end in `link/install_test.go:411-445`.
- **`.watching` has NO such guard** — any accepted `.watching` byte-replaces the local copy (only the generic presence path at `link/install.go:244-250` applies). Regression protection for `.watching` comes only from the display-side freshness rule (§5).
- **`.ear`** falls through to the same generic presence replace path — no epoch, no tombstone, no ordering guarantee.

**Scanning** — `treeWatcher`, `link/watch.go`:
- `scanPresence` (`link/watch.go:356-374`) reads `$KHALA_HOME/presence`, keeps regular files whose `presenceNode` parses, and on role `dial` keeps only files owned by `self`; enqueues a `candidate{class:"presence"}`.
- Presence is **age-governed**: `scanAgeGoverned` (`:291-298`) runs `scanPresence`, `scanStreams`, `scanMinds` only when `ageScanReady()` (`:300-317`) succeeds — which means the dial-side brain must have completed a `khala reconcile` under `KHALA_LINK_SCAN_GATE=1` (`link/brain.go:84-99`) **and** the presence/streams/minds fsnotify watches must register. Comment at `link/watch.go:308-309`: presence has no filename epoch, so a successful reconcile is its only age gate.
- **Periodic cadence**: `scanAll` on a ticker at `opts.scan` = **30 s** default (`link/main.go:184`, ticker `link/watch.go:108`); overridable via `KHALA_LINK_TEST_SCAN_INTERVAL` (`link/main.go:222`).
- **Event-driven**: any fsnotify event whose parent dir is `$KHALA_HOME/presence` arms a **100 ms** debounce timer, then runs `scanPresence` (`link/watch.go:149-159`, `:126-129`) — rationale comment `:110-112`: `khala send` refreshes its lease immediately before reconcile creates spool. A non-debounced single-file path also exists in `handleHint` (`:626-632`).
- Full rescans also on fsnotify error (`:130-135`) and at the test overflow hook (`:143-148`).

**mtime**: the native OFFER/DATA/STORED path **does not preserve source mtime**. `installer.receive` writes a fresh tmp then renames (`link/install.go:156-187`, `:244-250`) — there is no `os.Chtimes` anywhere in `link/install.go` (grep: `Chtimes` appears only in `link/pump.go:679` for `run/link.fresh` and in tests). The rsync fallback (`mailbox_rsync`, `bin/khala:1803-1868`) always passes `-a` (`:1857`), which includes `-t`, so **the rsync path does preserve mtime while the native link path does not**. Any dashboard freshness rule must therefore read the epoch *inside* the file, never the file mtime.

**Deletion does not propagate.** Both transports are additive: the link only ever offers files that exist (`scanPresence` iterates the directory), and rsync is called without `--delete` (`bin/khala:1857-1866`). `exchange_with_endpoint` pushes `presence/*@self`, `*@self.watching`, `*@self.watcher` then pulls the whole `presence/` dir (`bin/khala:2018-2030`), with the explicit comment at `bin/khala:2016-2017`: *"Watching-marker deletion is intentionally not propagated: remote copies become stale under the display-side freshness rule."* Removal happens only locally: `prune_presence` (`bin/khala:2702-2753`) deletes retention-expired heartbeats and watcher markers but **explicitly skips `.watching`** (`:2714-2715`), so a stale `.watching` on a remote node is never garbage-collected — it only ages out of the display. A `.ear` file, being unknown to `prune_presence`, would fall into the heartbeat branch and be rejected as an invalid heartbeat — see Open questions.

## 5. `bin/khala presence`

`cmd_presence` — `bin/khala:5019-5107`. Output header `ADDRESS<TAB>STATE<TAB>LAST_SEEN<TAB>WATCHING` (`:5043`).

**State** (`:5074-5082`), with `ttl` from config (default 120, `:5033-5041`) and `now = date +%s`:
- `now - epoch <= ttl` and node == self → `alive-here`;
- `now - epoch <= ttl` and node != self → `alive-elsewhere`;
- otherwise → `asleep`;
- `unknown` is emitted only in the second loop (`:5088-5103`) for an address that has a `.watching` marker but **no** heartbeat file (`LAST_SEEN` printed as `-`).
Rows skipped: any `*.watching`/`*.watcher` basename in loop 1 (`:5047-5049`); any address with a non-retired `.watcher` marker (`:5054-5056`, `watcher_marker_non_retired` `:458-466`); any heartbeat whose first token is `retired` (`:5060-5066`). A malformed filename or heartbeat is a hard `return 1` (`:5050-5053`, `:5068-5072`).
Trailing legend line at `:5104`, then `print_watcher_section`.

**LAST_SEEN source** = the normalized epoch integer read from `$KHALA_HOME/presence/<session>@<node>` (`:5059`, `:5073`) — printed raw, not humanized.

**Heartbeat file format** (`presence/<session>@<node>`) — `heartbeat()`, `bin/khala:608-621`: a single line, `date +%s`, newline-terminated, written to a `$KHALA_HOME/tmp/heartbeat.XXXXXX` then `mv`d into place. Live sample: `1788352202\n`. The only other legal shape is the tombstone `retired <epoch>\n` written by `cmd_retire` (`bin/khala:4064-4065`).
**Writers**: `khala send` (`bin/khala:3191`), `khala say` (`:3457`), `khala inbox` in every mode (`:4759`). The hooks do not write it directly — `session-start.sh` calls `khala profile`, `khala join`, `khala inbox --drain` and `khala node ensure`, and it is the `inbox --drain` that refreshes the heartbeat. So **a session that never sends/says/drains never appears in presence**, and a live but idle session ages to `asleep`.

**WATCHING column** = `watching_status "<presence_file>.watching" now ttl` (`bin/khala:5083-5084`, function `:720-745`):
- missing file → `-`;
- file must be line 1 = epoch (non-negative int), line 2 = interval (positive int), else prints `-` and warns;
- `yes` iff `now - epoch <= interval + ttl`; else `-`.
**`.watching` format**: exactly two lines, `<epoch>\n<interval>\n` (`refresh_watching_marker`, `bin/khala:623-638`). Live sample `1786821967\n30\n`.
**Writer**: only `khala watch` (`cmd_watch`), at `$KHALA_HOME/presence/<session>@<self>.watching` (`bin/khala:4566`), refreshed once per `--interval` seconds, **not** once per loop (`:4589-4596`; rationale comment `:4585-4588` — link mode loops at 1 s and the marker fan-out was measured at 57 events / 60 s).
**Deleter**: `watch_marker_cleanup` on EXIT/INT/TERM (`bin/khala:700-718`, `rm -f "$watch_marker"` at `:707`); nothing else, and retention skips it (§4).

**Watchers section** — `print_watcher_section` (`bin/khala:3789-3793`) prints only when `have_active_watchers` (`:3779-3787`), then the header `NAME<TAB>NODE<TAB>OWNER<TAB>CADENCE<TAB>LAST<TAB>STATE` from `print_watcher_table active` (`:3747-3777`). `khala presence --watchers` prints just this section (`:5028-5031`); `khala watcher list` prints it in `all` mode including retired rows (`:3801-3805`).
**`.watcher` format** — exactly 5 newline-terminated lines, validated by `read_watcher_marker` (`bin/khala:383-435`), written by `write_watcher_marker` (`:437-456`):
1. declared epoch, or `retired <epoch>` for a tombstone;
2. cadence seconds (bounded int);
3. owner `session@node`, a bare name, or `-`;
4. last-notify epoch (0 = never);
5. `active` or `silent <epoch>`.
Live sample: `1788372015\n3600\nsteno@b200\n1788402001\nactive\n`.
Writers: `khala watcher declare` (`:3862`), `khala watcher retire` (`:3898`), `khala notify` (last-notify line, `:3340`; it auto-declares a cadence-0 watcher if none exists, `:3327-3333`), and the dead-man state machine `watcher_deadman` (`:2545`). `LAST` is `relative_age(line4)` (`:3724-3745`, buckets `s/m/h/d`). `STATE` is `retired` for a tombstone else the first word of line 5.
Dead-man (`bin/khala:2472-2551`): `active` → `silent` (urgent notice) when age > 2×cadence; `silent` → `active` (info notice) when it drops back. Age anchor is line 4 if > 0 else line 1.

**`khala minds`** — `cmd_minds` (`bin/khala:3915-4029`). Address set = union of every parsable `presence/*` basename (with `.watching` stripped, `:3930-3937`) and every `minds/<node>/<session>` directory (`:3938-3945`), `sort -u`. Non-retired `.watcher` addresses are skipped (`:3950-3952`), as are `retired` heartbeats (`:3981`).
Columns (`:3947`): `ADDRESS STATE WATCHING MODEL MODEL_AGE EFFORT EFFORT_AGE ROLE ROLE_AGE CHARGE CHARGE_AGE FOCUS FOCUS_AGE STANCE STANCE_AGE FRESHNESS`.
`STATE` uses the same alive/asleep rule as presence but defaults to `unknown` when there is no heartbeat (`:3956-3980`). `WATCHING` reuses `watching_status`. The mind fields come from the **current** generation file (`current_mind_generation`, `:868-897` — highest `epoch.counter`) via `header_value` (`:3991-4009`). `*_AGE` = `relative_age(Declared-<Field>)`. `FOCUS`/`STANCE` are shown only when `State: active`, else `FRESHNESS=cleared` (`:4003-4018`). **Freshness rule**: `fresh` if `Declared-Focus > 0` and `now - Declared-Focus <= MIND_FRESH_SECONDS` (3600, `bin/khala:27`), `stale` if older, `-` if never declared (`:4010-4015`).

## 6. `khala watch`

`cmd_watch` — `bin/khala:4479-4672`. Flags: `--session`, `--interval` (default 30), `--max-wait` (default 0 = forever) (`:4485-4505`).

**Yield to the conduit (0.7.3)** — `bin/khala:4517-4531`: if `khala-link` is present it runs `runtime watch-ready --identity … --instance $KHALA_SESSION_INSTANCE --session-id … --caller-pid $$`; on exit 0 it prints `conduit has the ear` and returns 0 **without arming anything** (no marker, no lock, no loop). `runtimeWatchReady` (`link/runtime.go:1227-1275`) requires: a live owned lease for that identity; a registration that is `ConduitVerified`, `phase=="ready"`, has a socket, `lease.Epoch>0 && ==reg.LeaseEpoch`, matching pid/pidStart/claudeSessionId, a live process, an `Lstat`-able Unix socket; ownership proven by instance, session id, **or** pid ancestry (`:1266-1267`); and finally `if reg.ChannelSocket != "" && !reg.ChannelVerified` it errors `"conduit path unverified"` (`:1271-1273`). Only that one error string makes `khala watch` fall through and watch directly, printing `watch: conduit path unverified; watching directly` to stderr (`bin/khala:4526-4530`); every other failure also falls through, silently.

**When it does watch**: it takes a per-session lock dir `$KHALA_HOME/run/watch.<session>.lock.d` with an `owner` file of `<epoch>\npid <pid> watch\n<interval>\n` (`acquire_watch_lock` `:655-698`, `refresh_watch_lock` `:640-653`; stale after `2*(interval+ttl)`, `:683`; a live holder prints `이미 감시 중: <session> (pid N)` and returns 0). It writes/refreshes the `.watching` marker (§5), then each iteration: if `run/link.fresh` is younger than `TTL_LINK`=12 s (`bin/khala:25`, `:4600-4606`) it runs `reconcile_cycle` and sleeps 1 s, else it runs `run_sync_cycles` and sleeps `interval` (`:4607-4614`, `:4651-4655`). On finding mail or unread stream entries it prints `wake: delivery` or `wake: stream`, the count, then `Id<TAB>From` lines for letters and `Id<TAB>From<TAB>stream:<name>` for stream rows (`:4632-4648`, `collect_watch_stream_rows` `:4449-4477`) and exits 0. `--max-wait` exhaustion returns 3 (`:4662-4665`).

## 7. Link process model

`link/main.go:34-42` dispatches the first argument: `conduit` → `runConduit` (`link/conduit.go:92`), `runtime` → `runRuntime` (`link/runtime.go:78`); anything else is parsed as dial/serve options.
**Options** (`parseOptions`, `link/main.go:183-224`): `--serve`, `--peer <node>` (only with `--serve`), `restart`, `--max-object-bytes <n>` (default 1 MiB). `--serve` and `restart` are mutually exclusive. Scan interval default 30 s, env-overridable.
**runtime subcommands** (`link/runtime.go:83-110`): `register`, `bind`, `release`, `status`, `root`, `whoami`, `session`, `register-channel`, `watch-ready`, `daemon-status`, `process-start`, `native-warning`.
**Singletons**: dial takes `flock` on `$KHALA_HOME/run/link.lock` (`link/main.go:240-257`) and writes `run/link.status` = `pid <pid>\nepoch <unix>\n` (`:312-324`); serve takes `run/serve.<peer>.lock` with body `pid <pid>\npeer <peer>\n` (`:259-291`); the conduit takes `flock` on `<runtime>/conduit.lock` (`link/conduit.go:175-204`) **and** additionally refuses to start if `conduit.status.json` names a live foreign pid on the same boot (`:131-135`).
Carrier: dial spawns `ssh -T -o BatchMode=yes <addr> "exec ~/.local/bin/khala link --serve --peer <self>"` in its own process group (`carrierCommand` `link/main.go:427-442`, `runCarrier` `:381-425`); reconnect uses full-jitter backoff capped at 60 s over 7 attempt levels (`jitterDelay` `:461-475`). With no remote endpoint the dial process degrades to "node reconcile singleton only" (`:172-176`).

**`khala node ensure`** — `cmd_node`, `bin/khala:4383-4447`. Liveness probes first: conduit via `khala-link runtime daemon-status` (`:4394`), link via the pid in `run/link.status` + `kill -0` (`:4396-4399`). Then one of three supervisors:
1. **systemd --user** if `systemctl --user show-environment` succeeds (`:4404`): writes both units then `systemctl --user enable --now` each (`:4405-4413`).
2. **launchd** on Darwin (`:4414`): writes both plists, then `launchctl bootstrap gui/<uid> <plist>` falling back to `launchctl kickstart -k` (`:4415-4425`).
3. **setsid fallback** (`:4426-4439`) — `node_start_detached` (`:4368-4381`) runs `setsid sh -c 'KHALA_HOME=$1; export KHALA_HOME; "$2" conduit </dev/null >>"$3" 2>&1 &' …`. There is **no plain `nohup` path**; if none of systemd/launchd/setsid is available it errors out (`:4427-4430`).
Finally it warns if `~/.claude/settings.json` lacks `"crossSessionInbound": "accept"` (`node_accept_configured` `:4292-4297`, warning `:4443-4445`).

**Unit template** — `node_write_systemd_units` (`bin/khala:4299-4330`), written atomically into `$HOME/.config/systemd/user/` then `systemctl --user daemon-reload`:
- `khala-conduit.service`: `[Unit] Description=Khala conduit doorbell` / `[Service] Type=simple`, `Environment="KHALA_HOME=<root>"` (+ `KHALA_RUNTIME_DIR` if set), `ExecStart="<LINK_BINARY>" conduit`, `StandardOutput=append:<root>/log/conduit.log`, same for `StandardError`, `Restart=on-failure`, `[Install] WantedBy=default.target`.
- `khala-link.service`: same shape, `Environment="KHALA_HOME=<root>"`, `ExecStart="<KHALA_EXECUTABLE>" link`, `Restart=on-failure`, `WantedBy=default.target`, **no** Standard*/KHALA_RUNTIME_DIR lines.
**Plist template** — `node_write_launch_agents` (`bin/khala:4332-4366`), into `$HOME/Library/LaunchAgents/`: `dev.khala.conduit.plist` (`ProgramArguments = [<LINK_BINARY>, conduit]`, `EnvironmentVariables` with `KHALA_HOME` and optional `KHALA_RUNTIME_DIR`, `StandardOutPath`/`StandardErrorPath` → `<root>/log/conduit.log`, `KeepAlive`+`RunAtLoad` true) and `dev.khala.link.plist` (`[<KHALA_EXECUTABLE>, link]`, `KHALA_HOME` only, `KeepAlive`+`RunAtLoad`, no log paths).
`KHALA_EXECUTABLE` is the absolute path of `bin/khala` itself (`:4390`); `LINK_BINARY` comes from `find_link_binary` (§11).

**A third supervised process would need**: a `node_write_systemd_units` unit block + a `node_write_launch_agents` plist block + a `node_start_detached` case + a liveness probe and a `node_<x>_live` guard in `cmd_node` — all five sites are in `bin/khala:4299-4447`. If it is a Go subcommand it also needs a `case` in `link/main.go:36-42` and its own singleton (the existing pattern is a `flock` in `$KHALA_HOME/run/` or the runtime dir). **An on-demand foreground process** needs none of that: `cmd_status` (`bin/khala:4282-4290`) is the existing precedent — `require_config`, `find_link_binary`, exec the link binary with a runtime subcommand; nothing writes state.

## 8. Config file (`$KHALA_HOME/config`)

Plain text, whitespace-split lines, `#` comments. Live example on this node:
```
self b200
peer b200 b200
peer mini mini-t
mailbox mini
ttl 120
```

| Key | Grammar | Parsed in `bin/khala` | Parsed in Go |
|---|---|---|---|
| `self <node>` | one node name | `self_node()` `bin/khala:274-281` (`sed -n 's/^self //p'`) | `link/config.go:525-528`, validated `:552-554` |
| `mailbox <node>…` | one or more node names; multiple lines accumulate | `bin/khala:2042`, `:2861`, `:3040`, `:4536` | `link/config.go:529-532` |
| `peer <node> <addr>…` | mailbox name + one or more ssh coordinates | `sed -n "s/^peer <name> //p"`, `bin/khala:2050`, `:3050`, `:4546` | `link/config.go:533-536` |
| `ttl <seconds>` | positive int, default **120** | `bin/khala:5033-5041` (presence), `:3919-3922` (minds), `:4552-4560` (watch) | **not parsed by Go** |
| `retain <days>` | non-negative int, default **30** | `retain_days()` `bin/khala:206-216` | `link/config.go:537-547`, default set `:516`; duplicate or non-integer is a hard error |
| `retention-interval <seconds>` | 0..18 digits, default **300**, `0` = every pass | `retention_interval_seconds()` `bin/khala:228-238`; due-check `retention_due()` `:243-257` against `run/retention.stamp` mtime | **not parsed by Go** |
| `preserve <stream>…` \| `preserve all` | at most one line | `load_preserve_config()` `bin/khala:1150-1198`; selection `preserve_stream_selected()` `:1200-1208` | **not parsed by Go** |

Unknown keys are silently ignored by both parsers. `khala init <node>` seeds `self`, `peer <node> <node>`, `mailbox <node>`, `ttl 120`, `retain 30` (`bin/khala:2926-2932`).

**Node name**: always `self` from config; there is no other source. **Hub/peer list**: `mailbox` names the hub(s); `peer <mailbox> <coord…>` gives the ssh coordinates tried in order (`exchange_with_mailbox` `bin/khala:2040-2067`; `config.dialEndpoints` `link/config.go:558-578`, which skips `mailbox == self` and refuses absolute-path peers in production).
**A node does NOT know the full node list.** The nearest approximations, all incomplete: `spool/for/*` directory names (created on demand when a letter is addressed to that node, `bin/khala:2129-2130`); `streams/<stream>/<node>` shard names; `minds/<node>` names; and the `@node` suffixes of `presence/*` basenames. `presence/*` is the broadest in practice (77 entries on this node covering b200/mini/mbp/bw2/bw3/spark1/iisdata/proxmox), but it lists *sessions and watchers*, not nodes, and it only ever grows.

## 9. Streams and minds on disk

**Streams**: `$KHALA_HOME/streams/<stream>/<owner-node>/<Id>` — one file per entry, `Id = <epoch>.<pid>.<RANDOM>.<session>@<node>` (`new_message_id`, `bin/khala:747-751`; grammar `valid_message_id` `:151-167` and `messageIDPattern` `link/config.go:494`). Entry format (`cmd_say` `bin/khala:3425-3443`): header block then a blank line then the body —
```
Khala: 0.1
Id: <id>
From: <session>@<node>
Stream: <stream>
Date: <ISO8601 Z>
Type: entry
[Refs: <id>]
[Subject: <text>]

<body>
```
Validation (`validate_stream_file`, `bin/khala:1378-1410`): filename must equal `Id`; `From` node must equal the shard node; the address tail of the `Id` must equal `From`; `Stream` must match the directory; `Date` non-empty; `Type: entry`; `Khala: 0.1`; **no** `Expires:` line anywhere; `Refs` if present must be a valid Id.
**Rendering "recent N"**: `collect_stream_entries` (`bin/khala:1442-1468`) globs `streams/<stream>/*/*`, emits `epoch<TAB>Id<TAB>path`, `sort -k1,1n -k2,2`; `khala stream cat -n N` uses `collect_cat_stream_entries` (`:1470-1541`) which additionally merges `archive/streams/<stream>/*/*/*/*` and de-duplicates by `node/Id` (mismatched digests are a hard error), then `tail -n N` (`:4165-4166`). `khala streams` prints `STREAM JOINED ENTRIES LATEST` (`:4088-4131`).

**Local session's unread count**:
- `join/<session>/<stream>` — one line `<state> <epoch>`, state ∈ `joined` | `quiet` | `left` (`cmd_join` `bin/khala:3528-3529`, `cmd_leave` `:3560`). Live sample: `joined 1786651685`.
- `cursor/<session>/<stream>` — one line, the last-read `Id` (`atomic_line … cursor`, `bin/khala:4989`, `:3521`). Live sample: `1787841360.1281417.3897.nas-admin@iisdata`.
- `build_unread_stream_entries` (`bin/khala:1555-1623`) is the join: skip unless state is `joined`/`quiet`; drop entries older than `retain` days; include an entry when it sorts after the cursor (epoch-then-lexicographic, `:1607-1610`), or, with no cursor, when `epoch >= join_epoch` (`:1611-1613`). The Go conduit reimplements the same rule in `pendingStreams` (`link/conduit.go:1140-1197`, `compareMessageIDs` `:1199-1209`) for the doorbell's `streams:` count.

**Minds**: `$KHALA_HOME/minds/<node>/<session>/<generation>`, `generation = <epoch>.<counter>` (`valid_generation` `bin/khala:753-767`, `generationPattern` `link/config.go:495`). File shape (`write_mind_generation`, `bin/khala:1007-1029`) is a header block of **exactly 17 keys, each exactly once anywhere in the file**, then a blank line:
`Generation, Session, Node, State, Model, Effort, Role, Charge, Focus, Stance, Declared-State, Declared-Model, Declared-Effort, Declared-Role, Declared-Charge, Declared-Focus, Declared-Stance`.
`State` ∈ `active` | `cleared`; every `Declared-*` is an epoch integer (0 = never declared). Validation `validate_mind_file` (`bin/khala:778-866`). Only the highest generation survives a reconcile — `prune_mind_generations` GCs every lower one on **every** pass (`:2663-2670`); the current one is deleted only when retention is due and it is older than `retain` days (`:2671-2678`).
Writers: `khala mind` (`cmd_mind` `:3574`), `khala profile` (`:3659`), `khala retire` (`:4066-4075`, writes `State: cleared`).

**A minds table row** therefore joins three sources per address: `presence/<addr>` (STATE), `presence/<addr>.watching` (WATCHING), and `minds/<node>/<session>/<current>` (the 6 value fields + 6 declared epochs + freshness) — exactly what `cmd_minds` does at `bin/khala:3947-4025`.

## 10. Drain bookkeeping

`khala inbox --drain` — `cmd_inbox`, `bin/khala:4674-5017`. Defaults: `--max-n 20`, `--max-bytes 65536`, `--max-notices 10`, `--max-notice-bytes 16384` (`:4678-4681`).

What it records:
1. **Heartbeat touch**: `heartbeat "$inbox_session"` at `bin/khala:4759` — runs in *every* inbox mode, so a drain always refreshes `presence/<session>@<node>` to `now`.
2. **`new/` → `cur/` move plus an explicit `touch`**: letters `:4846-4851`, notices `:4895-4900`. The `touch` is deliberate — `prune_letter_archives` (`:2435-2470`) ages `inbox/*/cur/*` by **file mtime**, falling back to the Id epoch only when mtime predates it (comment `:2452-2455`).
3. **Stream cursor advance**: `atomic_line "$KHALA_ROOT/cursor/<session>/<stream>" "<id>" cursor` per printed entry (`:4989`).
4. **Summary line** to stdout: `drained: letters N, notices N, streams N` (`:5014-5015`).
5. It takes `run/brain.lock.d` for the whole drain (`:4816-4820`, released `:5008`) and unconditionally calls `prune_stream_entries 1` (`:4827`, comment `:4824-4826`).
6. `log/delivered` is **not** touched by drain — that file is the delivery-dedup log (`<epoch> <Id>` per line, `record_delivered` `:1758-1778`, pruned at 60 days `prune_delivered_log` `:2368-2395`), written when a letter is *installed into* the inbox, not when it is drained.

**"Last drain time / last drained generation" per identity is NOT derivable today.** There is no per-identity drain record anywhere: no `run/` file, no journal update, no counter. The closest proxies, all lossy:
- the newest mtime under `inbox/<identity>/cur/` — the last *letter* moved, but it is also bumped by ack settlement and expiry (see below) for the outbox, and it is empty for an identity that only ever drained notices under `--mail-only`;
- `presence/<identity>@<node>` epoch — but `khala send` and `khala say` refresh it too, so it means "any CLI activity", not "drained";
- the conduit's own `ACK` column (`link/runtime.go:1183-1191`) — `consumed` iff every letter of the newest journal now exists in `cur/`; this is a *per-generation* consumed flag, not a time, and it goes stale as soon as a newer generation rings.
The conduit-side generation is only in `deliveries/…/*.json`, which record the *ring*, never the drain.

**Acks / dead timestamps (0.8.0 state-entry mtime)**:
- `settle_acks` (`bin/khala:2322-2366`) moves `outbox/new/<Id>` → `outbox/acked/<Id>` and `touch`es it (`:2341-2345`).
- `expire_outbox` (`:2263-2305`) moves `outbox/new/<Id>` → `outbox/dead/<Id>` and `touch`es it (`:2295-2299`), after queuing a `bounce`.
So **the ack timestamp is the mtime of `outbox/acked/<Id>` and the dead timestamp is the mtime of `outbox/dead/<Id>`** — and `prune_letter_archives` (`:2445-2464`) reads exactly those mtimes for retention. There is no ack/dead time inside any file header. Same for the drained-letter timestamp: mtime of `inbox/<session>/cur/<Id>`.

## 11. Go module facts

**`link/go.mod`** (4 lines): module `github.com/Dev-Jahn/khala-network/link`, `go 1.23`, `require github.com/fsnotify/fsnotify v1.10.1`, `require golang.org/x/sys v0.13.0 // indirect`. `link/go.sum` has exactly those two modules. **Toolchain on this box is go1.26.5 at `/NHNHOME/jahn/go-toolchain/bin`** (`test/conduit.sh:6`), newer than the declared `go 1.23`.

**`embed` and `net/http` are NOT used anywhere in `link/`** (grep for `"net/http"`, `"embed"`, `embed.` → no matches). Adding an HTTP listener means a new import; both are stdlib so `go.mod`/`go.sum` need no change.

**Existing Go tests** (5 files, 61 tests):
- `link/config_test.go` (68 lines, 3 tests) — `retain` parsing incl. duplicate/invalid rejection; `validGeneration` matching the bash grammar; **`TestPresenceNodeAcceptsMarkerSuffixes` (`:59`) already asserts `.ear`**.
- `link/protocol_test.go` (165 lines, 8 tests) — frame round-trips, forged transfer-ID rejection, stream/mind offers binding stream/session into the transfer ID, byte-identical legacy encoding, a known presence transfer-ID digest, DATA byte-exactness, unknown-frame visibility, basename validation.
- `link/install_test.go` (445 lines, 15 tests) — fsync/rename/no-clobber, digest-mismatch quarantine, **mutable presence lease replace (`:106`)**, **presence suffix installs on dial+serve (`:125`)**, role ownership/traversal, stream & mind destination reconstruction, future/expired stream & mind handling, symlink rejection, concurrent no-clobber, stale-tmp recovery, **`.watcher` epoch regression + tombstone (`:411`)**.
- `link/watch_test.go` (183 lines, 3 tests) — age-governed scan requires a successful reconcile; mind eligible-view per role; mind watch re-registration after generation GC.
- `link/pump_test.go` (428 lines, 11 tests) — protocol mismatch, minor negotiation, mind minor gate, brain trigger without touching `link.fresh`, serve quiet timeout, reconcile singleton, bidirectional non-blocking, expired offers, unknown frames.
- `link/conduit_runtime_test.go` (1026 lines, 21 tests) — notice classification shaping both doorbells, info notices never ringing alone, the pre-write generation re-check (both directions), darwin bootId, boot-id-change reclaim, dead-registration reaping, verification log edge-triggering, runtime-lock no-rewrite, heal-lease no-op, watcher self-feed/debounce, released-lease reclaim, channel echo (verified vs not), live-owner protection, reclaim newest-without-flapping, fork-session takeover refusal, release semantics.

**`test/conduit.sh` rig** (900 lines) — reusable for an ears-snapshot test:
- Builds the binary itself: `(cd "$ROOT/link" && CGO_ENABLED=0 "$GO" build -o "$BIN" .)` (`test/conduit.sh:181`), with `GO=${GO:-/NHNHOME/jahn/go-toolchain/bin/go}` (`:6`).
- `RIG=${KHALA_TEST_ROOT:-$HOME/.khala-conduit-test-$$}`, `RUNTIME_BASE=$RIG/runtime` (`:7-9`).
- `runtime_env()` (`:81-84`) pins `KHALA_RUNTIME_DIR=$RUNTIME_BASE`, `KHALA_TEST_BOOT_ID=conduit-test-boot`, `KHALA_CLAUDE_SESSIONS_DIR=$RIG/cc-sessions` — the three envs that make a hermetic runtime plane.
- **Fake session/socket**: `start_listener` (`:86-104`) runs `test/conduit-listener.py <sock> <frames> <ready>` (a 61-line AF_UNIX SOCK_STREAM newline reader that appends each first line to the frames file), waits for the ready file, then **writes the fake Claude registry entry itself**: `{"pid":<listener pid>,"sessionId":…,"name":…,"version":"2.1.233","messagingSocketPath":<sock>}` into `$RIG/cc-sessions/<pid>.json` (`:99-101`). The listener process *is* the "session process", so pid/pidStart checks pass.
- `start_channel_listener` (`:106-120`) does the same for `$RUNTIME_BASE/channels/<instance>.sock` via `test/channel-listener.py`.
- `register_session` (`:122-136`) shells out to `khala bind --register <phase> --session-id … --pid … --socket … --kind … --cc-version 2.1.233`.
- `stage_letter` (`:138-159`) writes a complete `Khala: 0.1` envelope into `inbox/<id>/new/`.
- `start_conduit` (`:161-170`) launches `"$BIN" conduit` under the same envs plus `KHALA_CONDUIT_TEST_SCAN_INTERVAL=50ms`; callers add `KHALA_CONDUIT_TEST_BACKOFF=500ms`.
- Helpers `wait_file`/`wait_lines`/`line_count` (`:41-71`); Python comes from a per-run `uv venv --python 3.13` (`:180`).
- Cases H1–H20 are `# H<n>` comment / `pass H<n>` pairs; H10 (`:668-722`) is the `khala watch` yield case and H17/H18 (`:786-893`) cover runtime-plane and status/lock interaction.

**Release build**: the four `dist/` assets `khala-link-{linux,darwin}-{amd64,arm64}` are cross-compiled with `CGO_ENABLED=0 GOOS=… GOARCH=… go build -trimpath` (recorded at `report/notice-conduit-v08.md:100-102`; the same flags appear at `report/conduit-v05.md:157`). **There is no Makefile or build script in the repo** — the commands live only in those reports and `dist/` is not tracked by git (`git log -- dist/` is empty). `install.sh:431-439` maps `uname -s`/`uname -m` to `{linux,darwin}`/`{amd64,arm64}` and downloads `khala-link-<os>-<arch>` from `https://github.com/Dev-Jahn/khala-network/releases/download/v<version>/` (overridable with `KHALA_LINK_RELEASE_BASE`), chmod 755, into `$HOME/.khala/bin/khala-link` (`install.sh:442-459`). The SessionStart hook has an identical background autofetch (`plugin/hooks/session-start.sh:9-79`).

**How the CLI locates `khala-link`** — `find_link_binary`, `bin/khala:4218-4229`: `$KHALA_ROOT/bin/khala-link` first, else `<dir of bin/khala>/khala-link`; the first executable wins, else the function fails. `cmd_link` (`:4202-4216`) exports `KHALA_BRAIN=<abs path of bin/khala>` and `exec`s it. **There is no version check between the CLI and the binary** — `find_link_binary` only tests `-x`. The version *of the CLI itself* is checked in two other places: `install.sh:477-481` parses `khala version` to build the release URL, and `plugin/hooks/lib.sh:47` reads a candidate CLI file's declared `KHALA_VERSION` when deciding whether to overwrite `~/.local/bin/khala`.

## 12. Security-relevant facts for a tailnet HTTP listener

What today's read-only commands actually print:
- **`khala status`** (= `runtime status`, `link/runtime.go:1159-1197`): the **absolute runtime root path** on line 1 (e.g. `/run/user/2980/khala`), then per identity: identity name, pending count, owner flag, **instance UUID**, phase, `yes`/`-` for socket and channel, **CC version string**, adapter, RFC3339Nano last-attempt time, last status, ack, native status. It does **not** print socket paths, pids, or subjects.
- **`khala presence`** (`bin/khala:5043-5106`): `session@node` addresses, state, raw last-seen epoch, watching flag; then watcher name/node/**owner address**/cadence/relative last/state. No pids, no paths, no subjects.
- **`khala minds`** (`bin/khala:3947-4025`): address, state, watching, and the free-text `Model/Effort/Role/Charge/Focus/Stance` values — **`Focus` and `Stance` are operator-authored free text about what a session is working on** and are the most content-bearing thing on that table.
- **`khala inbox`** (list/read/--drain) prints letter **subjects and full bodies** (`bin/khala:4794-4798`, `:4813`, `:4855-4857`, `:4906-4908`). `khala stream cat` prints full entry bodies (`:4172-4177`). Neither belongs on an unauthenticated listener.

Where the sensitive values live, for a precise redaction list:
| Value | Location |
|---|---|
| Claude Code messaging socket path (e.g. `/tmp/cc-socks/<pid>.sock`) | `sessions/*.json` field `socketPath` (`link/runtime.go:30`); also `~/.claude/sessions/*.json` field `messagingSocketPath` (`link/runtime.go:451`) |
| Channel socket path | `sessions/*.json` `channelSocket` (`link/runtime.go:31`); always `<runtime>/channels/<instance>.sock` |
| Session pid / process start token | `sessions/*.json` `pid`,`pidStart`; `identities/*.lease` `pid`,`pidStart`; `channelPID`,`channelPIDStart` (`link/runtime.go:27-33`, `:52-54`) |
| Claude session UUID | `sessions/*.json` `claudeSessionId`, `identities/*.lease` `claudeSessionId` |
| Instance UUID | registration filename + `instanceId`; **already printed by `khala status`** |
| Conduit pid, runtime root | `conduit.status.json` `pid`,`pidStart`,`runtime` (`link/runtime.go:60-67`) |
| Link pid | `$KHALA_HOME/run/link.status` (`link/main.go:318`), `run/serve.<peer>.lock` (`:282`), `run/watch.<session>.lock.d/owner` (`bin/khala:643`) |
| **SSH coordinates** (`user@host` / ssh aliases) | `$KHALA_HOME/config` `peer` lines only (`bin/khala:2050`, `link/config.go:533-536`). No current read-only command prints them; `khala invite` echoes them into an error message (`bin/khala:3060-3065`) |
| Letter subjects & sender addresses | letter headers `Subject:`/`From:` in `inbox/*/new|cur/*`; mirrored into `deliveries/*/*/*.json` **only as `letterIds`** (ids, not subjects — `link/conduit.go:38`); into the doorbell frame `from:`/`subjects:` lines (`link/conduit.go:1013-1014`) and the channel `meta.subject` (`:1058`) |
| Letter/stream bodies | `inbox/*/{new,cur}/*`, `streams/*/*/*`, `archive/streams/**` |
| Session free-text focus/stance | `minds/<node>/<session>/<generation>` header keys `Focus:`/`Stance:` (`bin/khala:1017-1018`) |
| Node names / session names / watcher owners | everywhere; `presence/*` basenames are the widest exposure (77 files here, spanning 8 nodes) |

Two structural notes for a listener design: (a) the runtime dir is 0700 and ownership-checked on every access (`secureDirectory`, `link/runtime.go:163-192`), so a listener reading it inherits that trust boundary and must not weaken it; (b) `sanitizePreview` (`link/conduit.go:725-742`) already HTML-escapes `& < >` and strips CR/LF from `from`/`subject` before they reach the doorbell — the same helper is the natural thing to reuse if any of those strings reach HTML.

---

## Open questions / things I could not determine

1. **Nothing deletes `deliveries/<identity>/<instance>/*.json`.** I found no unlink for that tree in `link/` or `bin/khala` (only writes at `link/conduit.go:900` and reads at `:928`, `link/runtime.go:1205`). On this node `deliveries/ink/eab86744-…/` holds ≥9 journals. They are boot-scoped (`bootId` filtering at `link/conduit.go:939`, `link/runtime.go:1216`) so they become inert after a reboot, but the files persist. I could not find a stated retention policy — worth confirming with the maintainer before a dashboard enumerates them.
2. **`.ear` is accepted by the link but has no producer, no reader, and no format — and dropping one into `presence/` today breaks two commands.** `presenceNode` strips the suffix (`link/config.go:592`) and `installer.destination` will place it, but nothing writes one and no bash code knows the suffix. I verified with the actual `bin/khala:135-149` definitions that `valid_address "steno@alpha.ear"` returns 1. Consequences, each traced:
   - **`khala presence` hard-fails.** The skip `case` at `bin/khala:5047-5049` covers only `*.watching|*.watcher`, so a `.ear` file reaches the `valid_address` check at `:5050-5053` and the command does `error … ; return 1` — the whole table stops, on **every node the file replicates to**.
   - **`khala reconcile` reports failure on every retention pass (every `retention-interval`, 300 s by default — not every 1 s pass; correction 2026-09-03 by eddy@b200: `prune_presence` runs only when `reconcile_retention=1`, bin/khala:2851 at 7228ceb, and the stamp is touched before the sweep).** `prune_presence`'s `case` at `bin/khala:2714-2742` also covers only `.watching`/`.watcher`, so a `.ear` file falls through to `presence_record_epoch` (`:2687-2700`); unless its first line is a bare integer this raises `sync_error` (`:2744`), which sets `SYNC_FAILED=1` and makes `reconcile_cycle` return non-zero (`:2834`).
   - `cmd_minds` is safe by luck — its `valid_address` guard at `:3936` is an `&&`, so a `.ear` address is silently omitted rather than fatal.
   **Any 0.9.0 design that writes `.ear` into `presence/` must land the `bin/khala` skip-list changes at `:5047-5049` and `:2714-2742` on every node *before* the first file replicates.** This is the single highest-risk finding in this sheet.
3. **`.ears` (plural) is not accepted anywhere** — `link/config.go:592` lists exactly `.watching`, `.watcher`, `.ear`. A plural suffix would need a link change and a fleet-wide binary roll before any node could replicate it.
4. **The conduit's per-identity "why not verified" reason is memory-only** (`verificationReasons`, `link/conduit.go:87`) and reaches disk only as a log line in `$KHALA_HOME/log/conduit.log` (which rotates by truncation at 1 MiB, `link/logging.go:13`, `:32-34`). An ears snapshot that wants to show *why* an identity is deaf must have the conduit write it; it cannot be recovered from existing files.
5. **Last-drain time / last-drained generation per identity does not exist on disk** (§10). It must be added — the natural low-cost sites are a `touch` in `cmd_inbox`'s drain branch (which already touches every moved letter) or a small `run/` stamp per identity.
6. **The four `dist/` assets have no build script in the repo.** The `-trimpath` cross-compile flags are recorded only in prose in `report/notice-conduit-v08.md:100-102`. I did not build anything to confirm they still reproduce.
7. `deliveryJournal.PeerStatus` is written as the literal `"unknown"` at `link/conduit.go:825` and I found no code that ever sets another value. I could not determine whether this is dead scaffolding or an unimplemented feature.
8. I did not verify the launchd path on a real macOS node (this box is Linux/systemd); the plist templates are quoted verbatim from `bin/khala:4332-4366` but their runtime behaviour is untested by me.
