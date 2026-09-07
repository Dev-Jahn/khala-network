# Pull-only mailbox clients

Remote tool clients cannot assume that a successful command's response reaches
the caller. These optional CLI capabilities make retries safe without changing
the Khala 0.1 envelope or the existing carrier protocol.

`khala capabilities` prints:

```json
{"send_request_id":1,"inbox_ack_read":1}
```

## Idempotent send

```bash
KHALA_SESSION=web-client khala send worker@node --request-id unique-action-123 -s "Review" -m "Please review this change"
```

Keys contain 1..128 ASCII letters, digits, underscores or hyphens. They are scoped
to the sender session within this node. An exact retry returns the original Id;
reuse with different recipient, subject, TTL, reply, priority or body fails.
`-m` includes its normal trailing newline; stdin preserves exact bytes.
Without `--request-id`, send keeps its existing behavior.

The client must persist its intended key/content before calling send, then reuse
both after an ambiguous result. Different intended actions need different keys.
This is message-enqueue idempotency, not exactly-once execution by a recipient.

`requests/send/<session>/<key>/` retains the canonical input, immutable envelope
and publication marker. The intent is installed before the outbox entry. A
process interruption before publication is repaired by retry; an interruption
after publication is repaired by ordinary reconcile. If an uncommitted intent
expires, retry fails instead of silently creating a fresh message. This uses the
same local-filesystem assumptions as send; it does not add a power-loss/fsync
guarantee. Standard stale-lock recovery applies after a killed process.

Request records are **not automatically pruned** with outbox retention. Removing
a record permits that key to enqueue a new message; back up and retain these
records as long as clients might retry. They contain message bodies and need the
same protection as the mailbox. A retry after normal outbox pruning returns its
saved Id without resurrecting the message.

## Selective read acknowledgement

```bash
KHALA_SESSION=web-client khala inbox read "$message_id"
KHALA_SESSION=web-client khala inbox ack-read "$message_id"
```

`ack-read` accepts 1..100 exact message Ids in the selected session's mailbox.
It validates the whole batch before mutation and serializes with drain/reconcile
using the existing brain lock. Selected `new` files move to `cur`; already-read
files succeed without refreshing their retention timestamp. An I/O failure can
leave a partially moved batch; retry completes it. Missing Ids fail before any
move. No other mail, stream cursor, or full-drain stamp changes.

This CLI retains Khala's trusted-local-user security model. It cannot prove that
a caller fetched a message and it does not authenticate tool users. A remote
bridge must enforce user/mailbox ownership and issue its own read receipts.
Carrier ACK still means recipient disk delivery, not reading or task completion.

Run `python3 test/mailbox-compat.py` for isolated regression coverage.
