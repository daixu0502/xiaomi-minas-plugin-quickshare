#!/bin/sh
set -eu
PLUGIN_USER=${1:-}; PLUGIN_NAME=quickshare; PLUGIN_VERSION=1.0.0; PORT=19092
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

if [ -x "$SCRIPTS/control" ]; then PLUG_USER="$PLUGIN_USER" PLUG_HOME_DIR="$HOME_DIR" PLUG_SRC_DIR="$SRC" "$SCRIPTS/control" stop >/dev/null 2>&1 || true; fi
if ss -lnt 2>/dev/null | grep -q ":$PORT "; then echo "错误：端口 $PORT 已被其他服务占用" >&2; exit 1; fi
mkdir -p "$ROOT" "$HOME_DIR" "$VAR" "$SCRIPTS" "$SRC_PARENT" "$TMP_PARENT" "$WEB_DIR" "$ICON_DIR"

stage="$SRC_PARENT/.$PLUGIN_NAME.new.$$"; old="$SRC_PARENT/.$PLUGIN_NAME.old.$$"; rm -rf "$stage"; mkdir -p "$stage"
cp -R "$PAYLOAD/files" "$stage/files"; cp -R "$PAYLOAD/ui" "$stage/ui"
chmod 0755 "$stage/files/"*.sh "$stage/ui/quickshare.cgi"
chmod 0644 "$stage/files/"*.py "$stage/ui/index.html" "$stage/ui/app.js" "$stage/ui/style.css" "$stage/ui/config"
[ ! -d "$SRC" ] || mv "$SRC" "$old"; mv "$stage" "$SRC"; [ ! -d "$old" ] || rm -rf "$old"
cp "$PAYLOAD/scripts/control" "$SCRIPTS/control"; chmod 0755 "$SCRIPTS/control"
rm -f "$HOME_DIR/src" "$HOME_DIR/tmp"; ln -s "$SRC" "$HOME_DIR/src"; mkdir -p "$TMP"; ln -s "$TMP" "$HOME_DIR/tmp"

if [ ! -s "$VAR/server.secret" ]; then python3 -c 'import secrets,sys;open(sys.argv[1],"wb").write(secrets.token_bytes(32))' "$VAR/server.secret"; fi
[ -s "$VAR/shares.json" ] || printf '%s\n' '{"version":1,"settings":{"external_base":""},"shares":[]}' > "$VAR/shares.json"
chmod 0600 "$VAR/server.secret" "$VAR/shares.json"

digest="$TMP/digest.$$"; find "$SRC" -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f" | cut -d ' ' -f 1; done > "$digest"
abstract=$(sha256sum "$digest" | cut -d ' ' -f 1); rm -f "$digest"; size=$(du -sk "$SRC" | awk '{print $1*1024}'); now=$(date +%s)
jq -n --arg version "$PLUGIN_VERSION" --arg abstract "$abstract" --argjson timestamp "$now" --argjson size "$size" '{plugin:"quickshare",name:"文件快传",id:19092,version:$version,tags:["tool"],timestamp:$timestamp,desc:"带密码、有效期和次数限制的临时文件分享",developer:"Local",publisher:"Local",changelog:"首个版本：临时下载、上传入口、分享记录与一键失效",system:false,size:$size,port:"19092",type:"standard",forceupgrade:false,ext:{admin:true},hotplug:["net"],abstract:$abstract}' > "$HOME_DIR/INFO"

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
