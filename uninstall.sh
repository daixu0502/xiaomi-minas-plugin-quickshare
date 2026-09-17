#!/usr/bin/env bash
set -Eeuo pipefail
NAS_IP="${1:-}"; PLUGIN_USER="${2:-}"; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECT=false
if [[ "$(id -u)" == 0 ]] && command -v plugincenter >/dev/null 2>&1 && [[ -f /etc/config/plugin ]]; then
    DIRECT=true; [[ "${1:-}" =~ ^u[0-9]+$ ]] && { PLUGIN_USER="$1"; NAS_IP=""; }
fi
if [[ "$DIRECT" != true && -z "$NAS_IP" ]]; then
    [[ -t 0 ]] || { echo "错误：请运行 bash uninstall.sh <设备IP> [插件用户]" >&2; exit 2; }
    read -r -p "请输入设备 IP：" NAS_IP
fi
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [[ -z "$PLUGIN_USER" ]]; then
    users=()
    if [[ "$DIRECT" == true ]]; then
        shopt -s nullglob; for f in /data/plugin/u*.list; do u="${f##*/}"; u="${u%.list}"; [[ -d "/home/$u/plugin/quickshare" ]] && users+=("$u"); done; shopt -u nullglob
    else
        mapfile -t users < <(ssh "${ssh_options[@]}" "root@$NAS_IP" 'for d in /home/u*/plugin/quickshare; do [ -d "$d" ] && basename "$(dirname "$(dirname "$d")")"; done' | sort -u)
    fi
    ((${#users[@]})) || { echo "没有找到已安装的文件快传插件"; exit 2; }
    if ((${#users[@]} == 1)); then PLUGIN_USER="${users[0]}"; elif [[ -t 0 ]]; then select u in "${users[@]}"; do [[ -n "$u" ]] && { PLUGIN_USER="$u"; break; }; done; else echo "错误：请指定用户" >&2; exit 2; fi
fi
[[ "$PLUGIN_USER" =~ ^u[0-9]+$ ]] || exit 2
if [[ "$DIRECT" == true ]]; then exec /bin/sh "$SCRIPT_DIR/remote-uninstall.sh" "$PLUGIN_USER"; fi
ssh "${ssh_options[@]}" "root@$NAS_IP" /bin/sh -s -- "$PLUGIN_USER" < "$SCRIPT_DIR/remote-uninstall.sh"
