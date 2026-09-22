# Watcher lifecycle (0.9.9 CLI) report

## Scope and base

- Starting HEAD: `b1bcb3b0c0eb5e4eb89401102926604692f73836`.
- No version string, marker format, `.ear` format, Go code, hook, or wire-protocol change.
- `bin/khala` and `plugin/bin/khala` were copied together after each CLI edit and finish byte-identical.

## RED evidence

The regression properties were added first in `test/watcher-lifecycle.sh`. With the product files
still at the starting implementation, this exact command failed all four independent cases:

```sh
nice -n 19 taskset -c 20-71 bash test/watcher-lifecycle.sh
```

```text
    P1 notify --as undeclared succeeded
not ok P1
    P2 default presence printed watchers:
not ok P2
    P3 watcher owned by a retired session was not retired
not ok P3
    P4 three watcher W info notices did not fold to one
not ok P4
RESULT: FAIL (4 properties)
```

P3 was then strengthened to make the owned cadence-0 fixture 40 days old and to require the
non-target marker files to still exist, not merely lack a `retired` line. Before the retention
deletion fix, the same command produced:

```text
ok P1
ok P2
    P3 live owned cadence-0 watcher disappeared
not ok P3
ok P4
RESULT: FAIL (1 properties)
```

## Implementation

- P1: `notify` now rejects missing and retired local watcher markers before queueing a notice or
  writing the marker. The Korean diagnostic includes the complete
  `khala watcher declare <name> --cadence <초> --owner <session@node>` command. Explicit cadence-0
  declarations and re-declaration revival remain supported.
- P2: default `presence` stops after the session table and legend. The unchanged watcher-only path
  remains behind `presence --watchers`; `watcher list` still includes retired rows. The legend keeps
  the existing `watching` explanation and points to `khala watcher list`.
- P3: the retention-due pass scans only local-node watcher markers and rewrites L1 to
  `retired <epoch>` when the owner session is retired, a cadence watcher has been silent for more
  than seven days, or an ownerless legacy watcher has been idle for more than seven days. Silent
  retirement queues one info notice before the marker transition. Lines 2-6 are preserved. Local
  non-retired markers are no longer age-deleted; remote replica cleanup and retired-marker
  retention remain.
- P4: a newly delivered info notice removes only unread `new/` files whose header block has exact
  `Type: notice`, `Urgency: info`, and matching `From`. Dedup is checked first. Urgent notices,
  other watchers, `cur/`, and `log/delivered` are untouched.

## Existing assertions changed

- `test/notices.sh`
  - Replaced the auto-declare hint and owner-`-` assertions with explicit declarations for the
    successful `sentinel`, `local`, trigger, and custody fixtures.
  - Kept the existing envelope, last-notify, trigger, spool-custody, and no-ack assertions; only
    their old implicit-declaration setup changed.
- `test/watchers.sh`
  - Replaced “default presence contains `watchers:` and the watcher row” with the inverse assertions,
    the new legend pointer, and the same row assertion under `presence --watchers`.
  - Replaced “fully stale local non-retired watcher is deleted” with “local non-retired watcher is
    retained,” because local lifecycle transitions must replicate through a retired marker first.
- `test/ears.sh`, `test/cli-polish.sh`, and `test/local-roundtrip.sh` required no assertion changes.
- `test/watcher-lifecycle.sh` is the new focused P1-P4 suite. It also verifies no undeclared side
  effects, retired-name refusal, watcher-list compatibility, all retire exclusions, L2-L6
  preservation, exactly one silent-retirement notice, folding of three sequential info notices,
  urgent/other-watcher preservation, `cur/` preservation, and drain output.

## GREEN verification

All shell suites were run serially. Exact commands and results:

```sh
nice -n 19 taskset -c 20-71 bash test/watcher-lifecycle.sh
nice -n 19 taskset -c 20-71 bash test/watchers.sh
nice -n 19 taskset -c 20-71 bash test/notices.sh
nice -n 19 taskset -c 20-71 bash test/ears.sh
nice -n 19 taskset -c 20-71 bash test/cli-polish.sh
nice -n 19 taskset -c 20-71 bash test/local-roundtrip.sh
```

Each command ended with `RESULT: PASS`. The focused suite printed `ok P1` through `ok P4`.

Static checks:

```sh
bash -n bin/khala plugin/bin/khala test/watcher-lifecycle.sh test/watchers.sh test/notices.sh test/ears.sh test/cli-polish.sh test/local-roundtrip.sh
cmp bin/khala plugin/bin/khala
git diff --check b1bcb3b0c0eb5e4eb89401102926604692f73836..HEAD
```

All passed; `cmp` was silent. `shellcheck` is not installed on this host, as stated in the brief.

## Documentation

- `DESIGN.md` §5.4 and §9.6 now define session-only default presence, declared-only notify,
  retire-first local watcher lifecycle, unread info folding, and the updated CLI/retention contract
  in Korean.
- `README.md` declares watchers before notify examples and describes all four behaviors.
- `plugin/skills/khala/SKILL.md` gives the same operator-facing contract.
- Searches for the old auto-declare and “presence shows watchers below the session table” wording
  return no matches.
