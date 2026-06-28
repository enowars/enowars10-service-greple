#!/bin/sh
set -euo pipefail

python /echo.py &
echo_pid=$!

/greple/zig-out/bin/greple &
greple_pid=$!

term() {
	kill "$echo_pid" "$greple_pid" 2>/dev/null || true
}
trap term TERM INT

wait -n "$echo_pid" "$greple_pid"
status=$?
term
exit "$status"
