# Native origin ack/bounce spool lifetime — v0.9.8

Date: 2026-09-08

Starting HEAD: `6f6092e`

Branch: `task/spool-ack-transit`

## Outcome

The native dial path now removes origin-side `spool` copies after the hub returns
`STORED` only when the bounded envelope header declares `Type: ack` or
`Type: bounce`. The unlink uses the offered digest through `removeTransit`.
Message and notice copies remain retransmission/retention sources, and the serve
path is unchanged.

## RED evidence

The regression test was added and run against the starting implementation before
the fix (`c46281d` contains the RED test only):

```text
$ nice -n 19 taskset -c 20-71 go test -p 2 ./... -run '^TestDialSpoolCopyLifetimeAfterStored$' -count=1
--- FAIL: TestDialSpoolCopyLifetimeAfterStored (0.00s)
    --- FAIL: TestDialSpoolCopyLifetimeAfterStored/ack (0.00s)
        pump_test.go:209: dial ack copy remains after STORED: <nil>
    --- FAIL: TestDialSpoolCopyLifetimeAfterStored/bounce (0.00s)
        pump_test.go:209: dial bounce copy remains after STORED: <nil>
FAIL
FAIL    github.com/Dev-Jahn/khala-network/link  0.006s
FAIL
```

The message, notice, changed-ack, body-Type, and over-limit header subtests passed
in the same RED run; only the two leak assertions failed.

## Property results

| Property | Result | Evidence |
|---|---|---|
| P1 dial ack | PASS | `ack` subtest observes the exact DATA bytes at the simulated hub and an absent origin file after `STORED`. |
| P2 dial bounce | PASS | `bounce` subtest observes the exact DATA bytes at the simulated hub and an absent origin file after `STORED`. |
| P3 dial message | PASS | `message` subtest observes the origin file still present after `STORED`. |
| P4 dial notice | PASS | `notice` subtest observes the origin file still present after `STORED`. |
| P5 digest check | PASS | `changed ack` rewrites the source after DATA is received but before `STORED`; `removeTransit` refuses the digest mismatch and the changed bytes remain. |
| P6 bounded header | PASS | `body type is not a header` remains present; `type beyond header read limit` also remains present. Parsing stops at the first empty line and reads at most 64 KiB. |
| P7 validation | PASS | `go vet ./...`, `go test -p 2 ./...`, and `test/link.sh` all passed. The shell suite reported 20/20 and `RESULT: PASS`. |
| P8 design | PASS | DESIGN.md §5.2 now states that native link removes the origin copy after hub `STORED`, matching rsync lifetime semantics. |

## Commands run

Environment for Go validation:

```text
PATH=/NHNHOME/jahn/go-toolchain/bin:$PATH
GOTMPDIR=/NHNHOME/jahn/.cache/go-tmp
GOMAXPROCS=8
```

Commands and results:

```text
# Initial formatting/test command: did not reach tests because PATH was exported
# after gofmt; exited 127 with "command not found: gofmt". Command order was fixed.
gofmt -w link/pump_test.go && export PATH=... && ... go test ...

# RED (exit 1, expected assertions shown above)
nice -n 19 taskset -c 20-71 go test -p 2 ./... -run '^TestDialSpoolCopyLifetimeAfterStored$' -count=1

# GREEN targeted (PASS)
nice -n 19 taskset -c 20-71 go test -p 2 ./... -run '^TestDialSpoolCopyLifetimeAfterStored$' -count=1

# Full Go checks (PASS; tests completed in 7.285s)
nice -n 19 taskset -c 20-71 go vet ./...
nice -n 19 taskset -c 20-71 go test -p 2 ./...

# Shell link suite (PASS; 20/20)
nice -n 19 taskset -c 20-71 test/link.sh
```

## Commits

- `c46281d` — RED regression coverage
- `86abbfe` — native dial ack/bounce origin unlink fix
- documentation/report — this document and the DESIGN §5.2 sentence
