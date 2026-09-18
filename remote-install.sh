#!/bin/sh
set -eu
PLUGIN_USER=${1:-}; PLUGIN_NAME=quickshare; PLUGIN_VERSION=1.1.7
case "$PLUGIN_USER" in u[0-9]*) ;; *) echo "错误：无效插件用户" >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || { echo "错误：必须以 root 身份运行" >&2; exit 1; }
for cmd in jq python3 sha256sum plugincenter flock runuser ss; do command -v "$cmd" >/dev/null 2>&1 || { echo "错误：缺少 $cmd" >&2; exit 1; }; done
BUNDLE=$(CDPATH= cd "$(dirname "$0")" && pwd); PAYLOAD="$BUNDLE/payload"
ROOT="/home/$PLUGIN_USER/plugin"; HOME_DIR="$ROOT/$PLUGIN_NAME"; VAR="$HOME_DIR/var"; SCRIPTS="$HOME_DIR/scripts"
LIST="/data/plugin/$PLUGIN_USER.list"; [ -f "$LIST" ] && jq empty "$LIST" >/dev/null 2>&1 || { echo "错误：插件清单无效" >&2; exit 1; }
existing=""; [ -L "$HOME_DIR/src" ] && existing=$(readlink "$HOME_DIR/src" 2>/dev/null || true)
case "$existing" in */"$PLUGIN_USER"/plugin/pluginsrc/"$PLUGIN_NAME") POOL=${existing%/pluginsrc/$PLUGIN_NAME} ;; *) POOL="/nas/pool0/$PLUGIN_USER/plugin" ;; esac
SRC_PARENT="$POOL/pluginsrc"; TMP_PARENT="$POOL/plugintmp"; SRC="$SRC_PARENT/$PLUGIN_NAME"; TMP="$TMP_PARENT/$PLUGIN_NAME"
WEB_ROOT=$(jq -r '.settings.nginx_plugin // "/data/plugin/www"' /etc/config/plugin); WEB_DIR="$WEB_ROOT/$PLUGIN_USER"; WEB_LINK="$WEB_DIR/$PLUGIN_NAME"
ICON_DIR=/data/plugin/www/icon; ICON="$ICON_DIR/$PLUGIN_NAME.icon"; LOCK="/data/plugin/.$PLUGIN_USER.$PLUGIN_NAME.lock"; CRON="/etc/cron.d/quickshare-$PLUGIN_USER"

mkdir -p "$ROOT" "$HOME_DIR" "$VAR" "$SCRIPTS" "$SRC_PARENT" "$TMP_PARENT" "$WEB_DIR" "$ICON_DIR"
if [ -x "$SCRIPTS/control" ]; then PLUG_USER="$PLUGIN_USER" PLUG_HOME_DIR="$HOME_DIR" PLUG_SRC_DIR="$SRC" "$SCRIPTS/control" stop >/dev/null 2>&1 || true; fi
PORT_FILE="$VAR/server.port"; PORT=""
port_in_use(){ ss -lntH 2>/dev/null | awk -v suffix=":$1" '$4 ~ suffix "$" {found=1} END {exit !found}'; }
port_reserved(){ for f in /home/u*/plugin/quickshare/var/server.port; do [ -f "$f" ] || continue; [ "$f" = "$PORT_FILE" ] && continue; [ "$(tr -d '[:space:]' < "$f")" = "$1" ] && return 0; done; return 1; }
exec 8>/data/plugin/.quickshare-ports.lock; flock -x 8
if [ -s "$PORT_FILE" ]; then candidate=$(tr -d '[:space:]' < "$PORT_FILE"); case "$candidate" in ''|*[!0-9]*) candidate="" ;; esac; if [ -n "$candidate" ] && [ "$candidate" -ge 1024 ] && [ "$candidate" -le 65535 ] && ! port_in_use "$candidate" && ! port_reserved "$candidate"; then PORT="$candidate"; fi; fi
candidate=19092; while [ -z "$PORT" ] && [ "$candidate" -le 19191 ]; do if ! port_in_use "$candidate" && ! port_reserved "$candidate"; then PORT="$candidate"; break; fi; candidate=$((candidate+1)); done
[ -n "$PORT" ] || { echo "错误：19092-19191 没有可用端口" >&2; exit 1; }
printf '%s\n' "$PORT" > "$PORT_FILE"; chmod 0600 "$PORT_FILE"; flock -u 8

stage="$SRC_PARENT/.$PLUGIN_NAME.new.$$"; old="$SRC_PARENT/.$PLUGIN_NAME.old.$$"; rm -rf "$stage"; mkdir -p "$stage"
cp -R "$PAYLOAD/files" "$stage/files"; cp -R "$PAYLOAD/ui" "$stage/ui"
chmod 0755 "$stage/files/"*.sh "$stage/ui/quickshare.cgi"
chmod 0644 "$stage/files/"*.py "$stage/ui/index.html" "$stage/ui/app.js" "$stage/ui/client-bridge.js" "$stage/ui/style.css" "$stage/ui/config"
[ ! -d "$SRC" ] || mv "$SRC" "$old"; mv "$stage" "$SRC"; [ ! -d "$old" ] || rm -rf "$old"
cp "$PAYLOAD/scripts/control" "$SCRIPTS/control"; chmod 0755 "$SCRIPTS/control"
rm -f "$HOME_DIR/src" "$HOME_DIR/tmp"; ln -s "$SRC" "$HOME_DIR/src"; mkdir -p "$TMP"; ln -s "$TMP" "$HOME_DIR/tmp"

if [ ! -s "$VAR/server.secret" ]; then python3 -c 'import secrets,sys;open(sys.argv[1],"wb").write(secrets.token_bytes(32))' "$VAR/server.secret"; fi
[ -s "$VAR/shares.json" ] || printf '%s\n' '{"version":1,"settings":{"external_base":""},"shares":[]}' > "$VAR/shares.json"
chmod 0600 "$VAR/server.secret" "$VAR/shares.json"

digest="$TMP/digest.$$"; find "$SRC" -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f" | cut -d ' ' -f 1; done > "$digest"
abstract=$(sha256sum "$digest" | cut -d ' ' -f 1); rm -f "$digest"; size=$(du -sk "$SRC" | awk '{print $1*1024}'); now=$(date +%s)
jq -n --arg version "$PLUGIN_VERSION" --arg port "$PORT" --arg abstract "$abstract" --argjson timestamp "$now" --argjson size "$size" '{plugin:"quickshare",name:"文件快传",id:19092,version:$version,tags:["tool"],timestamp:$timestamp,desc:"带密码、有效期和次数限制的临时文件分享",developer:"Local",publisher:"Local",changelog:"修复电脑端底部遮挡并优化按钮和文字尺寸",system:false,size:$size,port:$port,type:"standard",forceupgrade:false,ext:{admin:true},hotplug:["net"],abstract:$abstract}' > "$HOME_DIR/INFO"

rm -f "$WEB_LINK"; ln -s "$SRC/ui" "$WEB_LINK"
python3 "$PAYLOAD/make_icon.py" "$ICON"; chmod 0644 "$ICON"
entry="$TMP/entry.$$"; jq -n --slurpfile f "$SRC/ui/config" --slurpfile i "$HOME_DIR/INFO" --argjson now "$now" '{resource:{mpk:"",icon:"",preview:null},status:"running",install:true,upgrade:false,enable:true,changetime:$now,icon:"/icon/quickshare.icon",progress:"100",frontend:$f[0],info:($i[0]|del(.abstract)),online:true}' > "$entry"
exec 9>"$LOCK"; flock -x 9; backup="$LIST.pre-quickshare.$now"; cp -p "$LIST" "$backup"; tmp="$LIST.quickshare.$$"; jq --slurpfile e "$entry" '.quickshare=$e[0]' "$LIST" > "$tmp"; jq empty "$tmp"; chmod --reference="$LIST" "$tmp" 2>/dev/null || chmod 0644 "$tmp"; chown --reference="$LIST" "$tmp" 2>/dev/null || chown "$PLUGIN_USER:$PLUGIN_USER" "$tmp"; mv -f "$tmp" "$LIST"; flock -u 9; rm -f "$entry"

cat > "$CRON" <<EOF
SHELL=/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
@reboot root /bin/sh -c 'sleep 65; PLUG_USER=$PLUGIN_USER PLUG_HOME_DIR=$HOME_DIR PLUG_SRC_DIR=$SRC $SCRIPTS/control start'
EOF
chmod 0644 "$CRON"; systemctl reload crond.service >/dev/null 2>&1 || true
chown -R "$PLUGIN_USER:$PLUGIN_USER" "$HOME_DIR" "$SRC" "$TMP"; chown -h "$PLUGIN_USER:$PLUGIN_USER" "$HOME_DIR/src" "$HOME_DIR/tmp" "$WEB_LINK"
chmod 0700 "$HOME_DIR" "$VAR" "$SRC" "$TMP"; chmod 0755 "$SRC/ui"
PLUG_USER="$PLUGIN_USER" PLUG_HOME_DIR="$HOME_DIR" PLUG_SRC_DIR="$SRC" "$SCRIPTS/control" start
plugincenter -u "$PLUGIN_USER" -p "$PLUGIN_NAME" enable >/dev/null 2>&1 || true
echo "文件快传 $PLUGIN_VERSION 已安装，局域网服务：http://设备IP:$PORT"
echo "APP 插件清单：$LIST"
echo "安装前清单备份：$backup"
