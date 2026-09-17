#!/bin/sh
set -eu
u=${1:-}; case "$u" in u[0-9]*) ;; *) echo "错误：无效用户" >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || exit 1
name=quickshare; home="/home/$u/plugin/$name"; list="/data/plugin/$u.list"; src=""; tmpdir=""
[ -L "$home/src" ] && src=$(readlink "$home/src" 2>/dev/null || true); [ -L "$home/tmp" ] && tmpdir=$(readlink "$home/tmp" 2>/dev/null || true)
if [ -x "$home/scripts/control" ]; then PLUG_USER="$u" PLUG_HOME_DIR="$home" PLUG_SRC_DIR="$src" "$home/scripts/control" stop >/dev/null 2>&1 || true; fi
plugincenter -u "$u" -p "$name" disable >/dev/null 2>&1 || true
if [ -f "$list" ] && jq empty "$list" >/dev/null 2>&1; then f="$list.quickshare-uninstall.$$"; jq 'del(.quickshare)' "$list" > "$f"; chmod --reference="$list" "$f" 2>/dev/null || chmod 0644 "$f"; chown --reference="$list" "$f" 2>/dev/null || true; mv -f "$f" "$list"; fi
rm -f "/data/plugin/www/$u/$name" "/etc/cron.d/quickshare-$u" "/data/plugin/.$u.$name.lock"
case "$src" in /nas/pool*/"$u"/plugin/pluginsrc/"$name") rm -rf "$src" ;; "") ;; *) echo "警告：未删除异常路径 $src" >&2 ;; esac
case "$tmpdir" in /nas/pool*/"$u"/plugin/plugintmp/"$name") rm -rf "$tmpdir" ;; "") ;; *) echo "警告：未删除异常路径 $tmpdir" >&2 ;; esac
[ "$home" = "/home/$u/plugin/quickshare" ] && rm -rf "$home"
if ! find /home -path '/home/u*/plugin/quickshare' -type d 2>/dev/null | grep -q .; then rm -f /data/plugin/www/icon/quickshare.icon; fi
systemctl reload crond.service >/dev/null 2>&1 || true
echo "文件快传已卸载；已上传到用户目录的文件不会被删除。"
