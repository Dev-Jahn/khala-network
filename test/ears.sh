#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KHALA=$ROOT/bin/khala
RIG=$HOME/.khala-ears-test-$$
FAILURES=

cleanup() {
    rm -rf -- "$RIG"
}

die() {
    printf '    %s\n' "$*" >&2
    exit 1
}

init_home() {
    init_target=$1
    init_node=${2-alpha}
    KHALA_HOME=$init_target "$KHALA" init "$init_node" >/dev/null \
        2>"$RIG/init-$init_node.err" || return 1
    printf 'retention-interval 0\n' >> "$init_target/config"
}

write_ear() {
    ear_path=$1
    ear_node=$2
    ear_generation=$3
    ear_written_at=$4
    ear_interval=$5
    ear_state=$6
    ear_complete=$7
    shift 7
    {
        printf 'ears 1\n'
        printf 'node %s\n' "$ear_node"
        printf 'generation %s\n' "$ear_generation"
        printf 'written-at %s\n' "$ear_written_at"
        printf 'interval %s\n' "$ear_interval"
        printf 'state %s\n' "$ear_state"
        printf 'complete %s\n' "$ear_complete"
        printf 'component conduit release=0.9.1 adapter=1 ears=1\n'
        printf 'mailbox -\n'
        printf 'link 0\n'
        for ear_identity in "$@"; do
            printf '%s\n' "$ear_identity"
        done
    } > "$ear_path"
}

warning_once() {
    warning_file=$1
    warning_path=$2
    [ "$(grep -Fc "$warning_path:" "$warning_file")" -eq 1 ] ||
        die "$warning_path did not produce exactly one warning"
}

property_c1() {
    home=$RIG/c1
    init_home "$home" || die "init failed"
    now=$(date +%s) || die "date failed"
    printf '%s\n' "$now" > "$home/presence/steno@alpha"
    printf '%s\n' "$now" > "$home/presence/extra@alpha"
    write_ear "$home/presence/conduit@alpha.ear" alpha 100 "$now" 60 running yes \
        'identity name=steno principal=session listening=yes route=socket reason=- unknown=future' \
        'identity name=echo principal=session listening=yes route=channel+socket reason=-' \
        'identity name=extra principal=session listening=yes route=channel reason=-'
    write_ear "$home/presence/conduit@gamma.ear" gamma 101 "$now" 60 stopping yes
    write_ear "$home/presence/conduit@partial.ear" partial 102 "$now" 60 running no \
        'truncated 3'
    printf 'ears 2\n' > "$home/presence/conduit@bad.ear"
    {
        printf 'ears 1\nnode huge\ngeneration 1\nwritten-at %s\ninterval 60\nstate running\ncomplete yes\n' "$now"
        awk 'BEGIN { for (i = 0; i < 132096; i++) printf "x"; printf "\n" }'
    } > "$home/presence/conduit@huge.ear"
    {
        printf 'ears 1\nnode lines\ngeneration 1\nwritten-at %s\ninterval 60\nstate running\ncomplete yes\n' "$now"
        for c1_line in $(seq 1 314); do printf 'unknown %s\n' "$c1_line"; done
    } > "$home/presence/conduit@lines.ear"
    write_ear "$home/presence/conduit@missing.ear" missing 1 "$now" 60 running yes \
        'identity name=missing principal=session route=socket reason=-'
    write_ear "$home/presence/conduit@duplicate.ear" duplicate 1 "$now" 60 running yes \
        'identity name=same principal=session listening=yes route=socket reason=-' \
        'identity name=same principal=session listening=no route=none reason=lease'
    write_ear "$home/presence/conduit@long.ear" long 1 "$now" 60 running yes
    awk 'BEGIN { printf "identity name=long principal=session listening=no route=none reason=lease x="; for (i=0;i<960;i++) printf "x"; printf "\n" }' \
        >> "$home/presence/conduit@long.ear"
    write_ear "$home/presence/conduit@mismatch.ear" other 1 "$now" 60 running yes
    write_ear "$home/presence/foo@beta.ear" beta 1 "$now" 60 running yes

    KHALA_HOME=$home "$KHALA" presence >"$RIG/c1-presence.out" \
        2>"$RIG/c1-presence.err" || die "presence failed"
    KHALA_HOME=$home "$KHALA" presence --watchers >"$RIG/c1-watchers.out" \
        2>"$RIG/c1-watchers.err" || die "presence --watchers failed"
    KHALA_HOME=$home "$KHALA" watcher list >"$RIG/c1-watcher-list.out" \
        2>"$RIG/c1-watcher-list.err" || die "watcher list failed"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/c1-minds.out" \
        2>"$RIG/c1-minds.err" || die "minds failed"
    KHALA_HOME=$home "$KHALA" reconcile >"$RIG/c1-reconcile.out" \
        2>"$RIG/c1-reconcile.err" || die "reconcile failed"

    grep -q '^conduit@' "$RIG/c1-presence.out" && die ".ear leaked into presence"
    grep -q '^conduit@' "$RIG/c1-minds.out" && die ".ear leaked into minds"
    grep -q $'^extra@alpha\t.*\tyes$' "$RIG/c1-presence.out" ||
        die "unknown identity key was not accepted"
    for bad in bad huge lines missing duplicate long mismatch; do
        warning_once "$RIG/c1-presence.err" "$home/presence/conduit@$bad.ear" || return 1
        warning_once "$RIG/c1-minds.err" "$home/presence/conduit@$bad.ear" || return 1
    done
    [ ! -s "$RIG/c1-watchers.err" ] || die "watchers-only read .ear files"
    [ ! -s "$RIG/c1-watcher-list.err" ] || die "watcher list read .ear files"
    ! grep -Fq 'foo@beta.ear' "$RIG/c1-presence.err" || die "wrong basename warned"
    [ ! -s "$RIG/c1-reconcile.err" ] ||
        die "reconcile parsed or rejected .ear: $(tr '\n' ' ' < "$RIG/c1-reconcile.err")"
}

property_c2() {
    home=$RIG/c2
    init_home "$home" || die "init failed"
    now=$(date +%s) || die "date failed"
    for address in socket@alpha direct@alpha no@alpha unknown@partial stale@gamma future@delta stop@omega clamp@sigma; do
        printf '%s\n' "$now" > "$home/presence/$address"
    done
    write_ear "$home/presence/conduit@alpha.ear" alpha 100 "$now" 60 running yes \
        'identity name=socket principal=session listening=yes route=socket reason=-' \
        'identity name=direct principal=session listening=no route=none reason=optin' \
        'identity name=no principal=session listening=no route=none reason=lease'
    printf '%s\n30\n' "$now" > "$home/presence/direct@alpha.watching"
    write_ear "$home/presence/conduit@partial.ear" partial 101 "$now" 60 running no \
        'truncated 1'
    write_ear "$home/presence/conduit@gamma.ear" gamma 102 "$((now - 181))" 60 running yes \
        'identity name=stale principal=session listening=yes route=socket reason=-'
    write_ear "$home/presence/conduit@delta.ear" delta 103 "$((now + 61))" 60 running yes \
        'identity name=future principal=session listening=yes route=channel reason=-'
    write_ear "$home/presence/conduit@omega.ear" omega 104 "$now" 60 stopping yes \
        'identity name=stop principal=session listening=yes route=socket reason=-'
    write_ear "$home/presence/conduit@sigma.ear" sigma 105 "$((now - 7200))" 86400 running yes \
        'identity name=clamp principal=session listening=yes route=socket reason=-'

    KHALA_HOME=$home "$KHALA" presence >"$RIG/c2-presence.out" \
        2>"$RIG/c2-presence.err" || die "presence failed"
    KHALA_HOME=$home "$KHALA" minds >"$RIG/c2-minds.out" \
        2>"$RIG/c2-minds.err" || die "minds failed"
    for output in "$RIG/c2-presence.out" "$RIG/c2-minds.out"; do
        grep -q $'^socket@alpha\t.*\tyes\t\|^socket@alpha\t.*\tyes$' "$output" ||
            die "fresh socket route is not watching in $output"
        grep -q $'^direct@alpha\t.*\tyes\t\|^direct@alpha\t.*\tyes$' "$output" ||
            die "fresh .watching union is not watching in $output"
        grep -q $'^missing@alpha\t.*\t-\t\|^missing@alpha\t.*\t-$' "$output" ||
            :
        grep -q $'^no@alpha\t.*\t-\t\|^no@alpha\t.*\t-$' "$output" ||
            die "listening=no is watching in $output"
        grep -q $'^unknown@partial\t.*\t?\t\|^unknown@partial\t.*\t?$' "$output" ||
            die "truncated missing identity is not unknown in $output"
        grep -q $'^stale@gamma\t.*\t-\t\|^stale@gamma\t.*\t-$' "$output" ||
            die "stale ear is watching in $output"
        grep -q $'^future@delta\t.*\t-\t\|^future@delta\t.*\t-$' "$output" ||
            die "clock-ahead ear is watching in $output"
        grep -q $'^stop@omega\t.*\t-\t\|^stop@omega\t.*\t-$' "$output" ||
            die "stopping ear is watching in $output"
        grep -q $'^clamp@sigma\t.*\t-\t\|^clamp@sigma\t.*\t-$' "$output" ||
            die "interval 86400 was not clamped: 2h-old ear is watching in $output"
    done
    grep -Fq '.ear = 노드 conduit이 듣는 중' "$RIG/c2-presence.out" ||
        die "presence legend lacks the .ear clause"

    hot=$RIG/c2-hot
    init_home "$hot" || die "hot init failed"
    hot_ear=$hot/presence/conduit@alpha.ear
    write_ear "$hot_ear" alpha 1 "$now" 60 running yes
    for c2_n in $(seq 1 64); do
        printf 'identity name=worker%s principal=session listening=yes route=socket reason=-\n' "$c2_n" >> "$hot_ear"
        printf '%s\n' "$now" > "$hot/presence/worker$c2_n@alpha"
    done
    shim=$RIG/c2-shim
    mkdir -p "$shim"
    printf '%s\n' '#!/bin/sh' 'printf "stat %s\n" "$*" >> "$EAR_FORK_LOG"' \
        'exec /usr/bin/stat "$@"' > "$shim/stat"
    printf '%s\n' '#!/bin/sh' 'printf "wc %s\n" "$*" >> "$EAR_FORK_LOG"' \
        'exec /usr/bin/wc "$@"' > "$shim/wc"
    printf '%s\n' '#!/bin/sh' 'printf "sed %s\n" "$*" >> "$EAR_FORK_LOG"' \
        'exec /usr/bin/sed "$@"' > "$shim/sed"
    printf '%s\n' '#!/bin/sh' 'printf "basename %s\n" "$*" >> "$EAR_FORK_LOG"' \
        'exec /usr/bin/basename "$@"' > "$shim/basename"
    chmod 755 "$shim/stat" "$shim/wc" "$shim/sed" "$shim/basename"
    : > "$RIG/c2-forks"
    EAR_FORK_LOG=$RIG/c2-forks PATH=$shim:/usr/bin:/bin KHALA_HOME=$hot \
        "$KHALA" presence >"$RIG/c2-hot.out" 2>"$RIG/c2-hot.err" ||
        die "instrumented presence failed"
    [ "$(grep -c '^stat ' "$RIG/c2-forks")" -eq 0 ] ||
        die "ear reading forked stat"
    [ "$(grep -c '^wc ' "$RIG/c2-forks")" -eq 0 ] ||
        die "ear identity parsing forked wc"
    ! grep -Fq '.ear' "$RIG/c2-forks" || die "ear reading added an external command"
    sed 's/^retention-interval 0$/retention-interval 300/' "$hot/config" \
        > "$hot/tmp/config.c2"
    mv "$hot/tmp/config.c2" "$hot/config"
    touch "$hot/run/retention.stamp"
    : > "$RIG/c2-forks"
    EAR_FORK_LOG=$RIG/c2-forks PATH=$shim:/usr/bin:/bin KHALA_HOME=$hot \
        "$KHALA" reconcile >"$RIG/c2-reconcile.out" 2>"$RIG/c2-reconcile.err" ||
        die "instrumented non-retention reconcile failed"
    ! grep -Fq '.ear' "$RIG/c2-forks" ||
        die "non-retention reconcile statted an ear snapshot"
}

property_c3() {
    home=$RIG/c3
    init_home "$home" || die "init failed"
    sed 's/^retain .*/retain 0/' "$home/config" > "$home/tmp/config.c3"
    mv "$home/tmp/config.c3" "$home/config"
    old=$home/presence/conduit@old.ear
    fresh=$home/presence/conduit@fresh.ear
    printf 'malformed\n' > "$old"
    write_ear "$fresh" fresh 1 "$(date +%s)" 60 running yes
    touch -d '2 days ago' "$old" || die "old touch failed"
    touch -d 'next hour' "$fresh" || die "fresh touch failed"
    KHALA_HOME=$home "$KHALA" reconcile >"$RIG/c3.out" 2>"$RIG/c3.err" ||
        die "retention reconcile failed"
    [ ! -e "$old" ] || die "aged ear survived retain 0"
    [ -f "$fresh" ] || die "fresh ear was pruned"
    ! grep -Fq "$old" "$RIG/c3.err" || die "malformed ear became a sync_error"
}

write_letter() {
    letter_path=$1
    letter_id=$2
    letter_type=$3
    mkdir -p "$(dirname "$letter_path")" || return 1
    {
        printf 'Khala: 0.1\n'
        printf 'Id: %s\n' "$letter_id"
        printf 'From: sender@beta\n'
        printf 'To: reader@alpha\n'
        printf 'Date: 2000-01-01T00:00:00Z\n'
        printf 'Type: %s\n' "$letter_type"
        [ "$letter_type" != notice ] || printf 'Urgency: info\n'
        printf 'Expires: 4102444800\n\nbody\n'
    } > "$letter_path"
}

assert_stamp_matches_summary() {
    stamp=$1
    output=$2
    summary=$(sed -n 's/^drained: letters \([0-9][0-9]*\), notices \([0-9][0-9]*\), streams \([0-9][0-9]*\)$/\1 \2 \3/p' "$output")
    IFS=' ' read -r stamp_magic stamp_version stamp_epoch stamp_before stamp_after \
        stamp_ring stamp_info stamp_streams stamp_status stamp_extra < "$stamp"
    [ -n "$summary" ] || die "drain summary missing"
    IFS=' ' read -r summary_letters summary_notices summary_streams <<EOF
$summary
EOF
    [ "$stamp_ring" -ge "$summary_letters" ] || die "stamp ring count omits letters"
    [ "$((stamp_ring - summary_letters + stamp_info))" -eq "$summary_notices" ] ||
        die "stamp ring/info counts do not match notice summary"
    [ "$stamp_streams" = "$summary_streams" ] || die "stamp stream count differs"
    [ "$stamp_magic $stamp_version" = 'drain 1' ] || die "stamp preamble invalid"
    case "$stamp_epoch" in ''|*[!0-9]*) die "stamp epoch invalid" ;; esac
    case "$stamp_before:$stamp_after" in
        -:-|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*) ;;
        *) die "stamp generation invalid" ;;
    esac
    case "$stamp_status" in ok|partial) ;; *) die "stamp status invalid" ;; esac
    [ -z "${stamp_extra-}" ] || die "stamp has extra tokens"
    [ "$(wc -l < "$stamp" | tr -d ' ')" -eq 1 ] || die "stamp is not one line"
}

property_c4() {
    home=$RIG/c4
    init_home "$home" || die "init failed"
    stamp=$home/run/drained/reader
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox list >/dev/null ||
        die "list failed"
    [ ! -e "$stamp" ] || die "list created stamp"
    write_letter "$home/inbox/reader/new/1.1.1.sender@beta" \
        1.1.1.sender@beta message || die "letter fixture failed"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --mail-only \
        >"$RIG/c4-mail.out" 2>"$RIG/c4-mail.err" || die "mail-only drain failed"
    assert_stamp_matches_summary "$stamp" "$RIG/c4-mail.out" || return 1
    grep -Eq '^drain 1 [0-9]+ - - 1 0 0 ok$' "$stamp" || die "mail-only stamp differs"
    stamp_before=$(stat -c %Y "$stamp")
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox read 1.1.1.sender@beta >/dev/null ||
        die "read failed"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox list >/dev/null ||
        die "second list failed"
    [ "$(stat -c %Y "$stamp")" = "$stamp_before" ] || die "read/list touched stamp"

    write_letter "$home/inbox/reader/new/2.1.1.sender@beta" \
        2.1.1.sender@beta notice || die "notice fixture failed"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain --notices-only \
        >"$RIG/c4-notice.out" 2>"$RIG/c4-notice.err" || die "notices-only drain failed"
    assert_stamp_matches_summary "$stamp" "$RIG/c4-notice.out" || return 1
    grep -Eq '^drain 1 [0-9]+ - - 0 1 0 ok$' "$stamp" || die "notices-only stamp differs"

    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/c4-empty.out" 2>"$RIG/c4-empty.err" || die "empty drain failed"
    assert_stamp_matches_summary "$stamp" "$RIG/c4-empty.out" || return 1
    grep -Eq '^drain 1 [0-9]+ - - 0 0 0 ok$' "$stamp" || die "empty drain differs"

    generation=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    mkdir -p "$home/bin"
    printf '%s\n' '#!/bin/sh' "printf '$generation 2 1\\n'" > "$home/bin/khala-link"
    chmod 755 "$home/bin/khala-link"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/c4-generation.out" 2>"$RIG/c4-generation.err" || die "generation drain failed"
    grep -Eq "^drain 1 [0-9]+ $generation $generation 0 0 0 ok$" "$stamp" ||
        die "pending generation was not stamped"
    [ ! -s "$RIG/c4-generation.err" ] || die "generation query warned"
    printf '%s\n' '#!/bin/sh' 'exit 64' > "$home/bin/khala-link"
    chmod 755 "$home/bin/khala-link"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/c4-old.out" 2>"$RIG/c4-old.err" || die "old binary drain failed"
    grep -Eq '^drain 1 [0-9]+ - - 0 0 0 ok$' "$stamp" || die "old binary did not yield dash generations"
    [ ! -s "$RIG/c4-old.err" ] || die "old binary warning was noisy"
    rm -f "$home/bin/khala-link"

    printf 'drain 1 1 - - 2 3 4 ok\n' > "$stamp"
    mkdir "$home/run/brain.lock.d" || die "lock fixture failed"
    printf '%s\npid %s holder\n' "$(date +%s)" "$$" > "$home/run/brain.lock.d/owner"
    shim=$RIG/c4-shim
    mkdir -p "$shim"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$shim/sleep"
    chmod 755 "$shim/sleep"
    if PATH=$shim:/usr/bin:/bin KHALA_HOME=$home KHALA_SESSION=reader \
        "$KHALA" inbox --drain >"$RIG/c4-lock.out" 2>"$RIG/c4-lock.err"; then
        die "locked drain succeeded"
    fi
    [ "$(cat "$stamp")" = 'drain 1 1 - - 2 3 4 ok' ] || die "failed drain changed stamp"

    rm -f "$home/run/brain.lock.d/owner"
    rmdir "$home/run/brain.lock.d" || die "lock fixture cleanup failed"
    write_letter "$home/inbox/reader/new/3.1.1.sender@beta" \
        3.1.1.sender@beta message || die "first partial fixture failed"
    write_letter "$home/inbox/reader/new/4.1.1.sender@beta" \
        4.1.1.sender@beta message || die "second partial fixture failed"
    partial_shim=$RIG/c4-partial-shim
    mkdir -p "$partial_shim"
    printf '%s\n' '#!/bin/sh' \
        'case "$1:$2" in *inbox/reader/new/*:*)' \
        '  count=0; [ ! -f "$MV_COUNT" ] || count=$(cat "$MV_COUNT")' \
        '  count=$((count + 1)); printf "%s\n" "$count" > "$MV_COUNT"' \
        '  [ "$count" -lt 2 ] || exit 71' \
        'esac' \
        'case "$2" in */run/drained/reader) [ -d "$KHALA_HOME/run/brain.lock.d" ] || exit 72 ;; esac' \
        'exec /usr/bin/mv "$@"' > "$partial_shim/mv"
    chmod 755 "$partial_shim/mv"
    if MV_COUNT=$RIG/c4-mv-count PATH=$partial_shim:/usr/bin:/bin KHALA_HOME=$home \
        KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/c4-partial.out" \
        2>"$RIG/c4-partial.err"; then
        die "partially failed drain succeeded"
    fi
    grep -Eq '^drain 1 [0-9]+ - - 1 0 0 partial$' "$stamp" ||
        die "partial drain did not stamp committed counts"
    partial_moved=0
    for partial_file in "$home"/inbox/reader/cur/[34].*; do
        [ -f "$partial_file" ] || continue
        partial_moved=$((partial_moved + 1))
    done
    [ "$partial_moved" -eq 1 ] || die "partial fixture did not commit exactly one move"
}

property_c5() {
    spoke=$RIG/c5-alpha
    mailbox=$RIG/c5-b200
    init_home "$spoke" alpha || die "spoke init failed"
    init_home "$mailbox" b200 || die "mailbox init failed"
    {
        printf 'self alpha\n'
        printf 'peer alpha %s\n' "$spoke"
        printf 'peer b200 %s\n' "$mailbox"
        printf 'mailbox b200\n'
        printf 'ttl 120\nretain 30\nretention-interval 300\n'
    } > "$spoke/config"
    now=$(date +%s) || die "date failed"
    write_ear "$spoke/presence/conduit@alpha.ear" alpha 1 "$now" 60 running yes \
        'identity name=worker principal=session listening=yes route=socket reason=-'
    KHALA_HOME=$spoke "$KHALA" sync >"$RIG/c5.out" 2>"$RIG/c5.err" ||
        die "local-path exchange failed: $(tr '\n' ' ' < "$RIG/c5.err")"
    cmp -s "$spoke/presence/conduit@alpha.ear" \
        "$mailbox/presence/conduit@alpha.ear" || die "ear was not pushed by rsync fallback"

    incoming=$mailbox/presence/conduit@beta.ear
    existing=$spoke/presence/conduit@beta.ear
    printf 'invalid\n' > "$incoming"
    write_ear "$existing" beta 10 "$now" 60 running yes
    cp "$existing" "$RIG/c5-valid-existing"
    KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-invalid.err" || die "invalid incoming sync failed"
    cmp -s "$existing" "$RIG/c5-valid-existing" || die "invalid incoming replaced existing"

    printf 'invalid\n' > "$existing"
    write_ear "$incoming" beta 11 "$now" 60 running yes
    KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-replace-invalid.err" || die "valid incoming sync failed"
    cmp -s "$existing" "$incoming" || die "valid incoming did not replace invalid existing"

    write_ear "$existing" beta 20 "$now" 60 running yes
    cp "$existing" "$RIG/c5-generation-20"
    write_ear "$incoming" beta 19 "$now" 60 running yes
    KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-lower.err" || die "lower generation sync failed"
    cmp -s "$existing" "$RIG/c5-generation-20" || die "lower generation replaced existing"

    cp "$existing" "$incoming"
    before_mtime=$(stat -c %Y "$existing")
    KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-equal.err" || die "equal generation sync failed"
    [ "$(stat -c %Y "$existing")" = "$before_mtime" ] || die "equal identical incoming was reinstalled"

    write_ear "$incoming" beta 20 "$now" 60 running yes \
        'identity name=different principal=session listening=no route=none reason=lease'
    KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-conflict.err" || die "conflict sync failed"
    cmp -s "$existing" "$RIG/c5-generation-20" || die "equal conflict replaced existing"
    set -- "$spoke"/quarantine/ears/beta.20.*
    [ -f "$1" ] || die "equal conflict was not quarantined"
    for conflict_n in 1 2 3 4 5 6 7 8 9; do
        write_ear "$incoming" beta 20 "$now" 60 running yes \
            "identity name=different-$conflict_n principal=session listening=no route=none reason=lease"
        KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-conflict-$conflict_n.err" ||
            die "conflict $conflict_n sync failed"
    done
    quarantine_count=0
    for quarantine_file in "$spoke"/quarantine/ears/beta.*; do
        [ -f "$quarantine_file" ] || continue
        quarantine_count=$((quarantine_count + 1))
    done
    [ "$quarantine_count" -le 8 ] || die "ear quarantine retained more than eight files"

    write_ear "$incoming" beta 21 "$now" 60 running yes
    install_started=$(date +%s)
    KHALA_HOME=$spoke "$KHALA" sync >/dev/null 2>"$RIG/c5-higher.err" || die "higher generation sync failed"
    cmp -s "$existing" "$incoming" || die "higher generation did not replace existing"
    [ "$(stat -c %Y "$existing")" -ge "$install_started" ] || die "install did not use local mtime"
}

expect_reserved() {
    reserved_name=$1
    reserved_label=$2
    shift 2
    if "$@" >"$RIG/c6-$reserved_label.out" 2>"$RIG/c6-$reserved_label.err"; then
        die "$reserved_label accepted reserved name"
    fi
    grep -Fqx "khala: 예약된 이름입니다: $reserved_name" \
        "$RIG/c6-$reserved_label.err" ||
        die "$reserved_label did not return the reserved-name diagnostic"
}

property_c6() {
    home=$RIG/c6
    init_home "$home" || die "init failed"
    for acquisition in conduit khala gateway operator khala-gateway; do
        expect_reserved "$acquisition" "env-$acquisition" env KHALA_HOME=$home KHALA_SESSION=$acquisition \
            "$KHALA" send human@alpha -m body || return 1
    done
    project=$RIG/c6-project
    mkdir -p "$project"
    printf 'gateway\n' > "$project/.khala-session"
    if (cd "$project" && env -u KHALA_SESSION KHALA_HOME=$home "$KHALA" \
        send human@alpha -m body >"$RIG/c6-file.out" 2>"$RIG/c6-file.err"); then
        die ".khala-session accepted reserved name"
    fi
    grep -Fqx 'khala: 예약된 이름입니다: gateway' "$RIG/c6-file.err" ||
        die ".khala-session diagnostic differs"
    expect_reserved operator send-as env KHALA_HOME=$home "$KHALA" \
        send human@alpha --as operator -m body || return 1
    expect_reserved conduit say-as env KHALA_HOME=$home "$KHALA" \
        say --as conduit -m body || return 1
    expect_reserved gateway notify-as sh -c \
        "printf '' | KHALA_HOME='$home' '$KHALA' notify human@alpha --as gateway" || return 1
    expect_reserved operator watch-session env KHALA_HOME=$home "$KHALA" \
        watch --session operator || return 1
    expect_reserved conduit watcher-declare env KHALA_HOME=$home "$KHALA" \
        watcher declare conduit --cadence 1 --owner human || return 1
    expect_reserved gateway watcher-beat env KHALA_HOME=$home "$KHALA" \
        watcher beat gateway || return 1
    expect_reserved gateway send-recipient env KHALA_HOME=$home KHALA_SESSION=human \
        "$KHALA" send gateway@alpha -m body || return 1
    expect_reserved operator notify-recipient sh -c \
        "printf '' | KHALA_HOME='$home' '$KHALA' notify operator@alpha --as guard" || return 1
    KHALA_HOME=$home KHALA_SESSION=human "$KHALA" send khala-gateway@alpha -m body \
        >"$RIG/c6-gateway-recipient.out" 2>"$RIG/c6-gateway-recipient.err" ||
        die "khala-gateway recipient was rejected"

    expect_reserved conduit owner-conduit env KHALA_HOME=$home "$KHALA" \
        watcher declare guard-a --cadence 1 --owner conduit@alpha || return 1
    KHALA_HOME=$home "$KHALA" watcher declare guard-b --cadence 1 \
        --owner khala-gateway@alpha >/dev/null || die "khala-gateway owner was rejected"

    printf '%s\n1\nhuman@alpha\n0\nactive\n%s\n' "$(date +%s)" "$(date +%s)" \
        > "$home/presence/operator@alpha.watcher"
    KHALA_HOME=$home "$KHALA" watcher retire operator >/dev/null || die "reserved watcher cleanup failed"
    KHALA_HOME=$home "$KHALA" retire conduit >/dev/null || die "reserved session cleanup failed"

    now=$(date +%s) || die "date failed"
    for hidden in conduit khala gateway operator; do printf '%s\n' "$now" > "$home/presence/$hidden@beta"; done
    printf '%s\n' "$now" > "$home/presence/khala-gateway@beta"
    printf '%s\n%s\nhuman@alpha\n0\nactive\n%s\n' "$now" 10 "$now" \
        > "$home/presence/operator@beta.watcher"
    mkdir -p "$home/minds/beta/gateway"
    for command in presence minds; do
        set -- $command
        label=$(printf '%s' "$command" | tr ' ' '-')
        KHALA_HOME=$home "$KHALA" "$@" >"$RIG/c6-$label-reader.out" \
            2>"$RIG/c6-$label-reader.err" || die "$command reader failed"
        grep -Eq '^(conduit|khala|gateway|operator)(@|[[:space:]])' \
            "$RIG/c6-$label-reader.out" && die "$command exposed a reserved row"
        grep -Eq '^khala-gateway(@|[[:space:]])' "$RIG/c6-$label-reader.out" ||
            die "$command hid khala-gateway row"
        [ ! -s "$RIG/c6-$label-reader.err" ] || die "$command warned for reserved rows"
    done
    printf '%s\n1\nhuman@alpha\n0\nactive\n%s\n' "$now" "$now" \
        > "$home/presence/khala-gateway@beta.watcher"
    for command in 'presence --watchers' 'watcher list'; do
        set -- $command
        label=$(printf '%s' "$command" | tr ' ' '-')
        KHALA_HOME=$home "$KHALA" "$@" >"$RIG/c6-$label-reader.out" \
            2>"$RIG/c6-$label-reader.err" || die "$command reader failed"
        grep -Eq '^(conduit|khala|gateway|operator)(@|[[:space:]])' \
            "$RIG/c6-$label-reader.out" && die "$command exposed a reserved row"
        grep -Eq '^khala-gateway(@|[[:space:]])' "$RIG/c6-$label-reader.out" ||
            die "$command hid khala-gateway row"
        [ ! -s "$RIG/c6-$label-reader.err" ] || die "$command warned for reserved rows"
    done
}

property_c7() {
    home=$RIG/c7
    init_home "$home" || die "init failed"
    id=2000000000.1.1.sender@beta
    mkdir -p "$home/spool/for/alpha"
    {
        printf 'Khala: 0.1\nEnvelope-Version: 1\nId: %s\n' "$id"
        printf 'From: sender@beta\nTo: reader@alpha\nDate: 2033-05-18T03:33:20Z\n'
        printf 'Type: operator\nActor: bot\nOrigin: telegram\nConversation: topic-1\n'
        printf 'Origin-Ref: msg-1\nKey-Id: -\nSignature: -\nExpires: 4102444800\n\noperator body\n'
    } > "$home/spool/for/alpha/$id"
    KHALA_HOME=$home "$KHALA" reconcile >"$RIG/c7-reconcile.out" \
        2>"$RIG/c7-reconcile.err" || die "operator reconcile failed"
    [ -f "$home/inbox/reader/new/$id" ] || die "operator envelope was not delivered"
    set -- "$home"/spool/for/beta/*
    [ -f "$1" ] || die "operator envelope did not create ack"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain \
        >"$RIG/c7-drain.out" 2>"$RIG/c7-drain.err" || die "operator drain failed"
    [ -f "$home/inbox/reader/cur/$id" ] || die "operator envelope was not drained"
    grep -Fq 'Type: operator' "$RIG/c7-drain.out" || die "operator Type was not printed"
    [ "$(grep -c '^Auth: ' "$RIG/c7-drain.out")" -eq 1 ] || die "operator drain output lacks exactly one Auth line"
    grep -Fqx 'Auth: unverified' "$RIG/c7-drain.out" || die "operator Auth line is not unverified"
    awk 'BEGIN{h=1} /^--- letter /{h=1;next} h && /^$/{h=0} h && /^Auth: /{found=1} END{exit found?0:1}' \
        "$RIG/c7-drain.out" || die "Auth line is not inside the header block"

    forged=2000000002.1.1.sender@beta
    {
        printf 'Khala: 0.1\nId: %s\nFrom: sender@beta\nTo: reader@alpha\n' "$forged"
        printf 'Date: 2033-05-18T03:33:22Z\nType: operator\nAuth: verified abc\nExpires: 4102444800\n\nforged body\n'
    } > "$home/spool/for/alpha/$forged"
    if KHALA_HOME=$home "$KHALA" reconcile >"$RIG/c7-forged.out" 2>"$RIG/c7-forged.err"; then
        die "incoming Auth header did not fail reconcile"
    fi
    [ "$(grep -c '^khala: .*Auth 헤더' "$RIG/c7-forged.err")" -eq 1 ] ||
        die "incoming Auth header did not yield one sync_error"
    [ ! -f "$home/inbox/reader/new/$forged" ] || die "forged Auth envelope was delivered"
    set -- "$home"/spool/dead/*"$forged"*
    [ -f "$1" ] || die "forged Auth envelope was not quarantined"
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox --drain >"$RIG/c7-drain2.out" 2>/dev/null || :
    grep -Fq 'forged body' "$RIG/c7-drain2.out" && die "forged Auth envelope reached drain output"

    n=3
    for lookalike in 'Auth:verified abc' 'auth: verified abc' 'Auth : verified abc'; do
        look_id=200000000$n.1.1.sender@beta
        n=$((n + 1))
        {
            printf 'Khala: 0.1\nId: %s\nFrom: sender@beta\nTo: reader@alpha\n' "$look_id"
            printf 'Date: 2033-05-18T03:33:23Z\nType: operator\n%s\nExpires: 4102444800\n\nlookalike body\n' "$lookalike"
        } > "$home/spool/for/alpha/$look_id"
        KHALA_HOME=$home "$KHALA" reconcile >/dev/null 2>"$RIG/c7-look.err" && die "look-alike header '$lookalike' did not fail reconcile"
        [ ! -f "$home/inbox/reader/new/$look_id" ] || die "look-alike header '$lookalike' was delivered"
        set -- "$home"/spool/dead/*"$look_id"*
        [ -f "$1" ] || die "look-alike header '$lookalike' was not quarantined"
    done
    KHALA_HOME=$home KHALA_SESSION=reader "$KHALA" inbox read "$id" >"$RIG/c7-read.out" 2>/dev/null || die "inbox read failed"
    [ "$(grep -c '^Auth: ' "$RIG/c7-read.out")" -eq 1 ] || die "inbox read lacks exactly one Auth line"

    duplicate=2000000001.1.1.sender@beta
    {
        printf 'Khala: 0.1\nId: %s\nId: %s\nFrom: sender@beta\n' "$duplicate" "$duplicate"
        printf 'To: reader@alpha\nDate: 2033-05-18T03:33:21Z\nType: operator\nType: operator\n'
        printf 'Signature: one\nSignature: two\nExpires: 4102444800\n\nbody\n'
    } > "$home/spool/for/alpha/$duplicate"
    if KHALA_HOME=$home "$KHALA" reconcile >"$RIG/c7-duplicate.out" 2>"$RIG/c7-duplicate.err"; then
        die "duplicate control headers did not fail reconcile"
    fi
    [ "$(grep -c '^khala: .*중복 제어 헤더' "$RIG/c7-duplicate.err")" -eq 1 ] ||
        die "duplicate control headers did not yield one sync_error"
    [ ! -f "$home/inbox/reader/new/$duplicate" ] || die "duplicate envelope was delivered"
    set -- "$home"/spool/dead/*"$duplicate"*
    [ -f "$1" ] || die "duplicate envelope was not quarantined"
}

property_c8() {
    home=$RIG/c8
    init_home "$home" || die "init failed"
    mkdir -p "$home/bin"
    printf '%s\n' '#!/bin/sh' 'printf "<%s>\n" "$@"' > "$home/bin/khala-link"
    chmod 755 "$home/bin/khala-link"
    KHALA_HOME=$home "$KHALA" dashboard --port 47001 --no-text >"$RIG/c8.out" 2>"$RIG/c8.err" ||
        die "dashboard wrapper failed"
    diff -u - "$RIG/c8.out" <<'EOF' || die "dashboard arguments were not verbatim"
<dashboard>
<--port>
<47001>
<--no-text>
EOF
    rm -f "$home/bin/khala-link"
    if KHALA_HOME=$home "$KHALA" dashboard >"$RIG/c8-missing.out" \
        2>"$RIG/c8-missing.err"; then
        die "dashboard without khala-link succeeded"
    fi
    grep -q 'khala-link' "$RIG/c8-missing.err" || die "missing binary error omits khala-link"
    "$KHALA" --help >"$RIG/c8-help.out" || die "top-level help failed"
    grep -q '^  khala dashboard \[--port N\] \[--no-text\]$' "$RIG/c8-help.out" || die "usage omits dashboard"
}

run_property() {
    property_number=$1
    property_title=$2
    property_function=$3
    if ( "$property_function" ); then
        printf 'ok %s — %s\n' "$property_number" "$property_title"
    else
        printf 'not ok %s — %s\n' "$property_number" "$property_title" >&2
        FAILURES="$FAILURES $property_number"
    fi
}

mkdir -p "$RIG" || exit 1
trap cleanup EXIT HUP INT TERM

run_property C1 '.ear files are isolated, bounded, and forward-compatible' property_c1
run_property C2 'WATCHING unions fresh direct watches with fresh conduit routes' property_c2
run_property C3 '.ear retention uses only mtime and never parses snapshots' property_c3
run_property C4 'drains atomically stamp epoch and summary counts only after lock success' property_c4
run_property C5 'rsync fallback pushes the local-node .ear snapshot' property_c5
run_property C6 'reserved identities are refused by writers and hidden by readers' property_c6
run_property C7 'operator envelopes deliver and duplicate control headers quarantine' property_c7
run_property C8 'dashboard execs khala-link with verbatim arguments' property_c8

if [ -n "$FAILURES" ]; then
    printf 'RESULT: FAIL properties%s\n' "$FAILURES"
    exit 1
fi
printf 'RESULT: PASS\n'
printf '.ear reader, drain stamp, rsync, reserved names, and dashboard wrapper passed\n'
