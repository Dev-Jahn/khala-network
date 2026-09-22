# T-CLI lane — Jev triage display in bin/khala (0.9.10 candidate)

Branch `task/triage-cli`, base `ad33ad9`. Design: `review/jev-triage-r1.md` §1.3, §2.3 items 2-3, §2.4, §2.5.

## What changed
- `bin/khala` (= `plugin/bin/khala`, `cmp` silent):
  - `triage_dir_ready` / `triage_tag` / `triage_column`: read `run/triage/<identity>/<id>.tag` only when
    `run`, `run/triage` and `run/triage/<identity>` are not symlinks and the last is a directory; the tag file must be a
    regular non-symlink file with exactly one LF-terminated line from the whitelist
    `fyi|action|reply|urgent|action,reply|action,urgent|reply,urgent|action,reply,urgent`. Anything else = no triage, silent.
  - drain: `Type: message` letters with a tag print `--- letter <id> --- · <tag>`; operator/notice lines unchanged.
  - `khala inbox` (the no-arg summary, which is the `Id\tFrom\tType` printer at ≈5679) and `khala inbox list`
    (`Id\tFrom\tSubject\tDate`): a trailing Triage column (tag or `-`) — **only when `run/triage/<identity>` exists**,
    so nodes without triage keep byte-identical output (and `test/cli-polish.sh` P5's exact 4-column check holds).
    Neither command prints a header row, so none was added.
  - `khala status`: after the `runtime:` line from `khala-link runtime status`, prints `triage: off` /
    `triage: on (<model>, threshold <t>)` / `triage: off (triage.conf must be a regular 0600 file)` (symlink,
    directory, or mode ≠ 600). Only `model` and `threshold` lines are parsed; `key`/`key-file` are skipped unread.
    Added (not in the brief): a malformed `model` (not `[A-Za-z0-9._-]{1,64}`) or `threshold` (not a decimal) prints
    `triage: invalid (triage.conf <key>)` instead of echoing arbitrary text. The link's exit code is preserved.
- `DESIGN.md` §9.6: `run/triage/<identity>/<id>.{json,tag}` in the `run/` list + subsection "Jev 판정 캐시(triage)".
- `README.md`: triage paragraph after the notices paragraph; `khala status` line in "Daily use".
- `plugin/skills/khala/SKILL.md`: hint-only paragraph after the operator `Auth:` rule.

## Decisions to note for main
- The brief says "`inbox list` prints `Id\tFrom\tType`" but that printer is the no-arg `khala inbox` summary; real
  `inbox list` prints subject/date. Both got the column (same rule).
- The column is conditional on the triage directory existing, rather than always present with `-`, to satisfy P1
  byte-identity. Consequence: once the conduit has created `run/triage/<identity>`, rows gain a 5th/4th field
  (`-` when untagged). The ChatGPT bridge (`khala-network-chatgpt`) does not parse CLI list output (checked: it
  reads its own mailbox store), so no downstream parser breaks.

## RED (commit 0b5fac6, test only, against base bin/khala)
```
    P1 status differs: runtime: /fixture/runtime|IDENTITY	PENDING|
FAIL P1
    P2 inbox summary lacks the Triage column: 1790097642.1.1.a@alpha,a@alpha,message|1790097642.1.2.b@alpha,b@alpha,message|1790097642.1.3.guard@alpha,guard@alpha,notice|
FAIL P2
    P3 summary shows a malformed tag: 1790097642.3.1.a@alpha,a@alpha,message|1790097642.3.2.a@alpha,a@alpha,message|1790097642.3.3.a@alpha,a@alpha,message|1790097642.3.4.a@alpha,a@alpha,message|1790097642.3.5.a@alpha,a@alpha,message|1790097642.3.6.a@alpha,a@alpha,message|1790097642.3.7.a@alpha,a@alpha,message|1790097642.3.8.a@alpha,a@alpha,message|
FAIL P3
    P4 summary shows a stray operator tag
FAIL P4
    P5 absent conf
FAIL P5
ok P6 — plugin copy identical, syntax clean
RESULT: FAIL
```
P6 (cmp + syntax) is an invariant guard and holds on the base by construction.

## GREEN (after 7861b5b; rerun at 1756dca)
Commands (from the worktree root, one at a time):
```
nice -n 19 taskset -c 20-71 bash test/triage.sh          # RESULT: PASS (P1-P6)
nice -n 19 taskset -c 20-71 bash test/local-roundtrip.sh # local store-and-forward, dedup, drain, expiry, and presence passed
nice -n 19 taskset -c 20-71 bash test/cli-polish.sh      # RESULT: PASS
nice -n 19 taskset -c 20-71 bash test/notices.sh         # RESULT: PASS
nice -n 19 taskset -c 20-71 bash test/watchers.sh        # RESULT: PASS
cmp bin/khala plugin/bin/khala                           # silent
bash -n bin/khala && sh -n bin/khala                     # ok
```
triage.sh output:
```
ok P1 — without triage, drain and list are unchanged and status says off
ok P2 — tags on the drain line and the list column; notice untouched
ok P3 — empty, bogus, long, symlink, directory, unordered, unterminated, multi-line tags ignored
ok P4 — stray tags on notice/operator are not shown; the message tag is
ok P5 — status triage line: off, on with values/defaults, 0600 rule, no key
ok P6 — plugin copy identical, syntax clean
RESULT: PASS
```
Not run here (owned by main after merge): test/conduit.sh, test/link.sh, test/plugin.sh, Go builds.
