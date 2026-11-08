#!/usr/bin/env bash
# Integration tests for the samba image.
# Usage: tests/test.sh [image]   (default image: samba-test)
set -u
IMAGE="${1:-samba-test}"
NAME="samba-it-$$"
FAILED=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILED=$((FAILED + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; }
trap 'cleanup; rm -rf "${TMP:-}"' EXIT
TMP=$(mktemp -d)

# start <docker-run-args...> -- <samba.sh args...>; waits until smbd answers
start() {
    cleanup
    local run=() args=()
    while [[ $# -gt 0 && "$1" != -- ]]; do run+=("$1"); shift; done
    shift
    args=("$@")
    docker run -d --name "$NAME" "${run[@]}" "$IMAGE" "${args[@]}" >/dev/null || return 1
    for _ in $(seq 1 30); do
        docker exec "$NAME" smbclient -L //localhost -U% -m SMB3 >/dev/null 2>&1 && return 0
        sleep 1
    done
    docker logs "$NAME" >&2
    return 1
}
smbc() { docker exec "$NAME" smbclient "$@"; }

echo "== script checks"
check "samba.sh passes bash -n" bash -n "$(dirname "$0")/../samba.sh"

echo "== usage"
out=$(docker run --rm "$IMAGE" -h 2>&1)
[[ "$out" == *Usage* ]] && pass "-h prints usage" || fail "-h prints usage"
[[ "$out" == *wsdd* ]] && pass "usage documents -d" || fail "usage documents -d"
docker run --rm "$IMAGE" -Z >/dev/null 2>&1 && fail "unknown option exits non-zero" || pass "unknown option exits non-zero"

echo "== smb.conf generation (no daemons)"
conf=$(docker run --rm "$IMAGE" -w TESTGRP -g "server signing = mandatory" \
    -s "pub;/srv/pub;yes;no;yes" -u "bob;pw" testparm -s 2>/dev/null)
grep -q "workgroup = TESTGRP" <<<"$conf" && pass "-w sets workgroup" || fail "-w sets workgroup"
grep -q "server signing = required" <<<"$conf" && pass "-g adds global option" || fail "-g adds global option"
grep -q "^\[pub\]" <<<"$conf" && pass "-s creates share" || fail "-s creates share"
grep -q "server min protocol = SMB2" <<<"$conf" && pass "SMB1 disabled by default" || fail "SMB1 disabled by default"

echo "== service: authenticated share"
if start -- -u "alice;secret" -p -s "data;/share;yes;no;no;alice" -d false; then
    pass "container starts and smbd answers"
    for _ in $(seq 1 15); do  # -p runs in the background: wait for it
        [[ "$(docker exec "$NAME" stat -c %U:%G /share)" == smbuser:smb ]] && break
        sleep 1
    done
    [[ "$(docker exec "$NAME" stat -c %U:%G /share)" == smbuser:smb ]] \
        && pass "-p sets share ownership to smbuser:smb" || fail "-p sets share ownership to smbuser:smb"
    procs=$(docker exec "$NAME" ps)
    grep -q "smbd -F" <<<"$procs" && pass "smbd running under supervisord" || fail "smbd running"
    [[ "$(docker exec "$NAME" cat /proc/1/cmdline | tr '\0' ' ')" == *supervisord* ]] \
        && pass "supervisord is PID 1" || fail "supervisord is PID 1"
    grep -q "wsdd" <<<"$procs" && fail "-d false disables wsdd" || pass "-d false disables wsdd"
    grep -q "nmbd" <<<"$procs" && fail "nmbd off without -n" || pass "nmbd off without -n"
    smbc -L //localhost -U% -m SMB3 | grep -Eq '^[[:space:]]*data[[:space:]]+Disk' && pass "share is listed" || fail "share is listed"
    echo hello >"$TMP/f.txt"; docker cp "$TMP/f.txt" "$NAME:/tmp/f.txt"
    smbc //localhost/data -U alice%secret -m SMB3 -c "put /tmp/f.txt f.txt" >/dev/null 2>&1 \
        && pass "authenticated upload works" || fail "authenticated upload works"
    docker exec "$NAME" test -f /share/f.txt && pass "file lands in share path" || fail "file lands in share path"
    [[ "$(smbc //localhost/data -U alice%secret -m SMB3 -c 'more f.txt' 2>/dev/null)" == *hello* ]] \
        && pass "download returns content" || fail "download returns content"
    smbc //localhost/data -U alice%wrong -m SMB3 -c ls >/dev/null 2>&1 \
        && fail "wrong password rejected" || pass "wrong password rejected"
    smbc //localhost/data -U% -m SMB3 -c ls >/dev/null 2>&1 \
        && fail "guest denied on private share" || pass "guest denied on private share"
    # lower the client floor too, so only the server can refuse SMB1
    smb1=$(smbc //localhost/data -U alice%secret -m NT1 --option='client min protocol=NT1' -c ls 2>&1)
    [[ "$smb1" == *"No compatible protocol selected by server"* ]] \
        && pass "server refuses SMB1" || fail "server refuses SMB1: $smb1"
    start_ts=$(date +%s); docker stop -t 20 "$NAME" >/dev/null; el=$(( $(date +%s) - start_ts ))
    [[ $el -lt 15 ]] && pass "graceful stop in ${el}s" || fail "graceful stop took ${el}s"
else
    fail "container starts and smbd answers"
fi

# needs the host ports 137-139, 445 and 3702 to be free (no local smbd/nmbd)
echo "== service: nmbd + wsdd (host network)"
if start --net host -- -n -w TESTGRP -s "pub;/pub;yes;no;yes"; then
    sleep 3
    procs=$(docker exec "$NAME" ps)
    grep -q "nmbd" <<<"$procs" && pass "-n starts nmbd" || fail "-n starts nmbd"
    grep -q "wsdd" <<<"$procs" && pass "wsdd starts by default" || fail "wsdd starts by default"
    grep -q -- "--workgroup TESTGRP" <<<"$procs" && pass "wsdd uses smb.conf workgroup" || fail "wsdd workgroup"
    smbc //localhost/pub -U% -m SMB3 -c ls >/dev/null 2>&1 && pass "guest share reachable" || fail "guest share reachable"
    docker exec "$NAME" pkill -f bin/wsdd; sleep 4
    docker exec "$NAME" pgrep -f bin/wsdd >/dev/null && pass "supervisord restarts wsdd" || fail "supervisord restarts wsdd"
else
    fail "host-network container starts"
fi

# wait_exit <seconds>: wait until the test container has exited
wait_exit() {
    for _ in $(seq 1 "$1"); do
        [[ "$(docker inspect -f '{{.State.Status}}' "$NAME")" == exited ]] && return 0
        sleep 1
    done
    return 1
}

echo "== smbd failure stops the container"
cleanup
# a CPU limit makes smbd take longer than supervisord's startsecs to fail, which
# once left the container crash-looping instead of exiting
if docker run -d --name "$NAME" --cpus 0.1 "$IMAGE" -g "[broken" -d false -s "p;/p;yes;no;yes" >/dev/null; then
    if wait_exit 60 && docker logs "$NAME" 2>&1 | grep -q "exited: smbd"; then
        pass "container exits when smbd cannot start (even slowly)"
    else
        fail "container exits when smbd cannot start (even slowly)"; docker logs "$NAME" >&2
    fi
else
    fail "container for the smbd start-failure test starts"
fi

echo "== smbd killed at runtime stops the container"
if start -- -d false -s "p;/p;yes;no;yes"; then
    docker exec "$NAME" pkill -f 'smbd -F'
    wait_exit 30 && pass "container exits when smbd is killed" \
        || { fail "container exits when smbd is killed"; docker logs "$NAME" >&2; }
else
    fail "container for the smbd-kill test starts"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all tests passed" || echo "$FAILED test(s) failed"
exit $((FAILED > 0))
