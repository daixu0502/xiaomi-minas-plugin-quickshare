#!/bin/sh
set -u
u=${1:-}; case "$u" in u[0-9]*) ;; *) exit 1 ;; esac
home="/home/$u/plugin/quickshare"; src=$(readlink "$home/src" 2>/dev/null || true)
[ -x "$home/scripts/control" ] || exit 1
PLUG_USER="$u" PLUG_HOME_DIR="$home" PLUG_SRC_DIR="$src" "$home/scripts/control" start
