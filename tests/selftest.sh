#!/bin/sh
set -eu
USER_ID=${1:-u103868178}; case "$USER_ID" in u[0-9]*) ;; *) exit 2 ;; esac
FILES=$(CDPATH= cd "$(dirname "$0")/../payload/files" && pwd)
STATE=$(mktemp -d /tmp/quickshare-selftest.XXXXXX)
COOKIE="$STATE/cookie"; DOWNLOADED="$STATE/downloaded"; PORT=19093
TEST_FILE=$(runuser -u "$USER_ID" -- mktemp "/nas/pool0/$USER_ID/data/QuickShare-selftest-XXXXXX.txt")
UPLOAD_NAME="QuickShare-upload-selftest-$$.txt"; UPLOAD_FILE="/nas/pool0/$USER_ID/data/$UPLOAD_NAME"
cleanup() {
    if [ -s "$STATE/server.pid" ]; then pid=$(cat "$STATE/server.pid" 2>/dev/null || true); case "$pid" in *[!0-9]*|'') ;; *) [ -r "/proc/$pid/cmdline" ] && tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q quickshare_server.py && kill "$pid" 2>/dev/null || true ;; esac; fi
    case "$TEST_FILE" in "/nas/pool0/$USER_ID/data/QuickShare-selftest-"*.txt) rm -f "$TEST_FILE" ;; esac
    case "$UPLOAD_FILE" in "/nas/pool0/$USER_ID/data/QuickShare-upload-selftest-"*.txt) rm -f "$UPLOAD_FILE" ;; esac
    case "$STATE" in /tmp/quickshare-selftest.*) rm -rf "$STATE" ;; esac
}
trap cleanup EXIT HUP INT TERM
[ ! -e "$UPLOAD_FILE" ] || { echo "测试上传文件已存在" >&2; exit 1; }
ss -lnt | grep -q ":$PORT " && { echo "测试端口已占用" >&2; exit 1; } || true
printf 'QuickShare self-test payload\n' > "$TEST_FILE"; chown "$USER_ID:$USER_ID" "$TEST_FILE"; chown "$USER_ID:$USER_ID" "$STATE"
runuser -u "$USER_ID" -- python3 -c 'import secrets,sys;open(sys.argv[1],"wb").write(secrets.token_bytes(32))' "$STATE/server.secret"
RELATIVE="data/$(basename "$TEST_FILE")"
DOWNLOAD_TOKEN=$(runuser -u "$USER_ID" -- env PYTHONPATH="$FILES" python3 -c 'from quickshare_lib import Store;import sys;s=Store(sys.argv[1],sys.argv[2]);print(s.create("download",sys.argv[3],"TestPass123",3600,1)["token"])' "$STATE" "$USER_ID" "$RELATIVE")
UPLOAD_TOKEN=$(runuser -u "$USER_ID" -- env PYTHONPATH="$FILES" python3 -c 'from quickshare_lib import Store;import sys;s=Store(sys.argv[1],sys.argv[2]);print(s.create("upload","data","",3600,1)["token"])' "$STATE" "$USER_ID")
runuser -u "$USER_ID" -- sh -c "nohup python3 '$FILES/quickshare_server.py' --state '$STATE' --port '$PORT' > '$STATE/server.log' 2>&1 & echo \$! > '$STATE/server.pid'"
n=0; until curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null; do n=$((n+1)); [ "$n" -lt 20 ] || { cat "$STATE/server.log" >&2; exit 1; }; sleep 1; done

code=$(curl -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" --data-urlencode 'password=TestPass123' "http://127.0.0.1:$PORT/auth/$DOWNLOAD_TOKEN")
[ "$code" = 303 ] || { echo "密码认证失败：HTTP $code" >&2; exit 1; }
curl -fsS -b "$COOKIE" "http://127.0.0.1:$PORT/d/$DOWNLOAD_TOKEN" -o "$DOWNLOADED"
cmp "$TEST_FILE" "$DOWNLOADED"
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE" "http://127.0.0.1:$PORT/d/$DOWNLOAD_TOKEN")
[ "$code" = 404 ] || { echo "次数限制未生效：HTTP $code" >&2; exit 1; }

code=$(curl -sS -o "$STATE/upload.json" -w '%{http_code}' --data-binary "@$TEST_FILE" "http://127.0.0.1:$PORT/upload/$UPLOAD_TOKEN?name=$UPLOAD_NAME")
[ "$code" = 200 ] && jq -e '.ok == true' "$STATE/upload.json" >/dev/null || { cat "$STATE/upload.json" >&2; exit 1; }
cmp "$TEST_FILE" "$UPLOAD_FILE"
code=$(curl -sS -o /dev/null -w '%{http_code}' --data-binary "@$TEST_FILE" "http://127.0.0.1:$PORT/upload/$UPLOAD_TOKEN?name=$UPLOAD_NAME")
[ "$code" = 410 ] || { echo "上传次数限制未生效：HTTP $code" >&2; exit 1; }

runuser -u "$USER_ID" -- env PYTHONPATH="$FILES" python3 -c 'from quickshare_lib import Store,ShareError;import sys;s=Store(sys.argv[1],sys.argv[2]);
try:s.resolve_path("data/../plugin","dir");raise SystemExit(1)
except ShareError:pass' "$STATE" "$USER_ID"
! grep -q 'TestPass123' "$STATE/shares.json"
curl -sS -D "$STATE/headers" -o /dev/null "http://127.0.0.1:$PORT/health"
grep -qi "connect-src 'self'" "$STATE/headers"
echo "SELFTEST_OK"
