#!/bin/sh
# Liveness: xray process running (binds :8089 on start).
# Alpine busybox has no `nc -z` and may lack `pgrep`, so use pidof.
pidof xray >/dev/null 2>&1 || exit 1
exit 0
