#!/usr/bin/env bash
set -Eeuo pipefail

NAS_IP="${1:-}"
PLUGIN_USER="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIRECT_INSTALL=false
if [[ "$(id -u)" == "0" ]] && command -v plugincenter >/dev/null 2>&1 && [[ -f /etc/config/plugin ]]; then
    DIRECT_INSTALL=true
    if [[ "${1:-}" =~ ^u[0-9]+$ ]]; then PLUGIN_USER="$1"; NAS_IP=""; fi
fi

if [[ "$DIRECT_INSTALL" != true && -z "$NAS_IP" ]]; then
    [[ -t 0 ]] || { echo "错误：请运行 bash deploy.sh <设备IP> [插件用户]" >&2; exit 2; }
    read -r -p "请输入小米智能存储 IP：" NAS_IP
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
choose_user() {
    local choices=("$@")
    ((${#choices[@]})) || { echo "错误：没有扫描到插件用户" >&2; exit 2; }
    if ((${#choices[@]} == 1)); then PLUGIN_USER="${choices[0]}"; echo "自动选择唯一用户：$PLUGIN_USER"; return; fi
    [[ -t 0 ]] || { echo "错误：扫描到多个用户，请显式指定用户" >&2; exit 2; }
    echo "请选择要安装文件快传插件的用户："; PS3="请输入序号："
    select selected in "${choices[@]}"; do [[ -n "$selected" ]] && { PLUGIN_USER="$selected"; break; }; done
}

if [[ -z "$PLUGIN_USER" ]]; then
    users=()
    if [[ "$DIRECT_INSTALL" == true ]]; then
        shopt -s nullglob
        for f in /data/plugin/u*.list; do u="${f##*/}"; u="${u%.list}"; [[ "$u" =~ ^u[0-9]+$ ]] && [[ -d "/home/$u" ]] && users+=("$u"); done
        shopt -u nullglob
    else
        [[ "$NAS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "错误：无效设备 IP" >&2; exit 2; }
        mapfile -t users < <(ssh "${ssh_options[@]}" "root@$NAS_IP" 'for f in /data/plugin/u*.list; do u=${f##*/}; u=${u%.list}; case "$u" in u[0-9]*) [ -d "/home/$u" ] && printf "%s\n" "$u" ;; esac; done' | sort -u)
    fi
    choose_user "${users[@]}"
fi
[[ "$PLUGIN_USER" =~ ^u[0-9]+$ ]] || { echo "错误：无效插件用户" >&2; exit 2; }

work_dir="$(mktemp -d)"
cleanup() { [[ -n "${work_dir:-}" && "$work_dir" == /tmp/* ]] && rm -rf "$work_dir"; }
trap cleanup EXIT HUP INT TERM
stage="$work_dir/quickshare-plugin"
mkdir -p "$stage"
cp -R "$SCRIPT_DIR/payload" "$stage/payload"
cp "$SCRIPT_DIR/remote-install.sh" "$stage/remote-install.sh"

if [[ "$DIRECT_INSTALL" == true ]]; then
    echo "检测到设备本机运行，直接安装……"
    /bin/sh "$stage/remote-install.sh" "$PLUGIN_USER"
    exit 0
fi

archive="$work_dir/quickshare-plugin.tgz"
tar -C "$work_dir" -czf "$archive" quickshare-plugin
remote="/tmp/quickshare-plugin-$$-$RANDOM.tgz"
scp "${ssh_options[@]}" "$archive" "root@$NAS_IP:$remote"
ssh "${ssh_options[@]}" "root@$NAS_IP" "REMOTE='$remote' USER_ID='$PLUGIN_USER' /bin/sh -s" <<'REMOTE_SCRIPT'
set -eu
tmp="/tmp/quickshare-install-$$"
trap 'rm -rf "$tmp" "$REMOTE"' EXIT HUP INT TERM
mkdir -p "$tmp"
tar -xzf "$REMOTE" -C "$tmp"
/bin/sh "$tmp/quickshare-plugin/remote-install.sh" "$USER_ID"
REMOTE_SCRIPT
echo "安装完成。请刷新小米智能存储 APP，打开“文件快传”。"
