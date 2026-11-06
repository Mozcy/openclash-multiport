#!/bin/sh
# Run on the router as root. Backups contain deployed files, not proxy data.
set -eu
umask 077
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STATUS=/usr/lib/lua/luci/view/openclash/status.htm
CUSTOM=/etc/openclash/custom/openclash_custom_overwrite.sh
BACKUP_ROOT=${HOME:-/root}/openclash-multiport-back
LEGACY=/usr/lib/lua/luci/controller/oc_multiport.lua

fail() { echo "错误：$*" >&2; exit 1; }
TTY_STATE=''
LOCK_HELD=''
restore_terminal() {
    if [ -n "$TTY_STATE" ]; then
        stty "$TTY_STATE" 2>/dev/null || :
        TTY_STATE=''
        printf '\033[?25h'
    fi
}
cleanup() {
    restore_terminal
    [ -z "$LOCK_HELD" ] || rmdir "$LOCK_HELD" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

# BusyBox sh compatible: stty/dd handle keys without dialog or Bash read flags.
picker_rows() {
    printf '%s\n' "$picker_options" | awk -v selected="$SELECTED" -v start="${2:-1}" -v color="${1:-0}" -v view="$picker_view" '
        !color || (NR >= start && NR < start + 10) {
            text = $0
            if (view == "backup") {
                split($1, stamp, "-")
                date = substr(stamp[1],1,4) "-" substr(stamp[1],5,2) "-" substr(stamp[1],7,2)
                time = substr(stamp[2],1,2) ":" substr(stamp[2],3,2) ":" substr(stamp[2],5,2)
                suffix = stamp[3] == "" ? "" : "#" stamp[3]
                text = sprintf("%s  %s  %-4s [%s]", date, time, suffix, $2)
            }
            if (color && NR == selected) printf "\033[48;5;236m\033[1;36m  > %2d  %s  \033[0m\n", NR, text
            else if (color) printf "\033[37m    %2d  %s\033[0m\n", NR, text
            else printf "  %2d. %s\n", NR, text
        }'
}
render_picker() {
    printf '\033[2J\033[H\n  \033[1;36mOpenClash Multiport\033[0m\n'
    printf '  \033[90m────────────────────────────────────────────────────────\033[0m\n\n'
    printf '%s\n' "$picker_title" | sed 's/^/  /'
    if [ "$picker_view" = backup ]; then
        printf '\n  \033[90m共 %s 个备份 · 按时间从旧到新\033[0m\n' "$picker_count"
    elif [ "$picker_view" = confirm ]; then
        printf '\n  \033[90m仅恢复文件，端口数据和当前运行配置保留。\033[0m\n'
    fi
    printf '\n'
    picker_start=$(((SELECTED - 1) / 10 * 10 + 1))
    picker_rows 1 "$picker_start"
    printf '\n  \033[90m────────────────────────────────────────────────────────\033[0m\n'
    printf '  \033[36m↑↓\033[0m 选择   \033[36mEnter\033[0m 确认   \033[36mEsc / q\033[0m 返回   \033[90m%s / %s\033[0m\n' "$SELECTED" "$picker_count"
}
select_item() {
    picker_title=$1; picker_options=$2; SELECTED=${3:-1}; picker_view=${4:-menu}
    picker_count=$(printf '%s\n' "$picker_options" | wc -l | tr -d ' ')
    if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && command -v stty >/dev/null 2>&1; then
        TTY_STATE=$(stty -g) || return 1
        stty -echo -icanon min 1 time 0 || { restore_terminal; return 1; }
        printf '\033[?25l'
        picker_enter=$(printf '\n.'); picker_enter=${picker_enter%.}
        while :; do
            render_picker
            picker_key=$(dd bs=1 count=1 2>/dev/null; printf '.')
            picker_key=${picker_key%.}
            if [ "$picker_key" = "$(printf '\033')" ]; then
                stty min 0 time 1
                picker_sequence=$(dd bs=1 count=2 2>/dev/null)
                stty min 1 time 0
                case "$picker_sequence" in
                    '[A'|'OA') SELECTED=$((SELECTED - 1)) ;;
                    '[B'|'OB') SELECTED=$((SELECTED + 1)) ;;
                    '') restore_terminal; return 1 ;;
                esac
            else
                case "$picker_key" in
                    '') restore_terminal; return 1 ;;
                    "$picker_enter"|"$(printf '\r')") restore_terminal; return 0 ;;
                    q|Q|"$(printf '\004')") restore_terminal; return 1 ;;
                    [1-9]) [ "$picker_key" -gt "$picker_count" ] || SELECTED=$picker_key ;;
                esac
            fi
            [ "$SELECTED" -gt 0 ] || SELECTED=$picker_count
            [ "$SELECTED" -le "$picker_count" ] || SELECTED=1
        done
    fi
    # Non-interactive terminals can enter a number instead of arrow keys.
    printf '\n%s\n\n' "$picker_title"
    picker_rows
    printf '输入编号（q 返回）：'
    read -r picker_number || return 1
    case "$picker_number" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#picker_number}" -le 6 ] || return 1
    picker_number=$(printf '%s' "$picker_number" | sed 's/^0*//')
    [ -n "$picker_number" ] && [ "$picker_number" -ge 1 ] && [ "$picker_number" -le "$picker_count" ] || return 1
    SELECTED=$picker_number
}
files() {
    cat <<'FILES'
status.htm|/usr/lib/lua/luci/view/openclash/status.htm
oc-proxy-multiport.css|/www/luci-static/resources/openclash/css/oc-proxy-multiport.css
oc-proxy-multiport.js|/www/luci-static/resources/openclash/js/oc-proxy-multiport.js
backend/openclash_proxy_multiport.lua|/usr/lib/lua/luci/controller/openclash_proxy_multiport.lua
backend/openclash_proxy_multiport.rb|/usr/share/openclash/openclash_proxy_multiport.rb
FILES
}
targets() {
    files | cut -d '|' -f 2
    printf '%s\n' "$CUSTOM" "$LEGACY"
}
check_openclash() {
    [ "$(id -u)" = 0 ] || fail '请以 root 执行'
    [ -f /etc/init.d/openclash ] && [ -d /etc/openclash ] || fail '未安装 OpenClash，已退出'
    [ -f "$STATUS" ] || fail "OpenClash 状态页不存在：$STATUS"
    version=''
    if command -v opkg >/dev/null 2>&1; then
        version=$(opkg status luci-app-openclash 2>/dev/null | awk '$1 == "Version:" {print $2; exit}')
    fi
    if [ -z "$version" ] && command -v apk >/dev/null 2>&1; then
        version=$(apk list -I luci-app-openclash 2>/dev/null | awk '/^luci-app-openclash-/ {sub(/^luci-app-openclash-/, ""); print $1; exit}')
    fi
    echo "OpenClash 版本：${version:-未知（软件包信息不可用）}"
    if [ -x /etc/openclash/clash ]; then
        core_version=$(/etc/openclash/clash -v 2>/dev/null) || core_version='无法读取'
        printf '内核版本：%s\n' "$core_version"
    else
        echo '内核版本：未找到 /etc/openclash/clash'
    fi
}
refresh_luci() {
    for cache in /tmp/luci-indexcache /tmp/luci-indexcache.*; do
        [ ! -f "$cache" ] || rm -f "$cache"
    done
    /etc/init.d/rpcd restart
}
backup_current() {
    kind=original
    if grep -q 'id="oc-multiport"' "$STATUS" ||
        [ -f /usr/lib/lua/luci/controller/openclash_proxy_multiport.lua ] ||
        [ -f /usr/share/openclash/openclash_proxy_multiport.rb ] ||
        { [ -f "$LEGACY" ] && grep -q '^-- OC_MULTIPORT_BACKEND_V' "$LEGACY"; }; then
        kind=plugin
    fi
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    stamp=$(date '+%Y%m%d-%H%M%S')
    snapshot=$BACKUP_ROOT/$stamp
    suffix=0
    while [ -e "$snapshot" ]; do
        suffix=$((suffix + 1)); snapshot=$BACKUP_ROOT/$stamp-$suffix
    done
    mkdir "$snapshot"
    printf '%s\n' "$kind" > "$snapshot/.kind"
    if [ "$kind" = original ]; then
        cp -p "$STATUS" "$snapshot/status.htm"
    else
        targets | while IFS= read -r target; do
            [ ! -f "$target" ] || cp -p "$target" "$snapshot/$(basename "$target")"
        done
    fi
    : > "$snapshot/.complete"
    echo "已备份（$kind）：$snapshot"
}
hook() {
    # Only modify our marked block; preserve all other overwrite logic.
    ruby - "$CUSTOM" "$1" <<'RUBY'
path, action = ARGV
text = File.binread(path).gsub("\r\n", "\n")
start_marker = '# OC_MULTIPORT_HOOK_BEGIN'
end_marker = '# OC_MULTIPORT_HOOK_END'
if text.include?(start_marker) != text.include?(end_marker)
  abort '覆写脚本中的多端口标记不完整，请检查'
end
text = text.gsub(/^[ \t]*# OC_MULTIPORT_HOOK_BEGIN\n.*?^[ \t]*# OC_MULTIPORT_HOOK_END[^\n]*(?:\n|\z)/m, '')
if action == 'install'
  block = <<~SH
    # OC_MULTIPORT_HOOK_BEGIN
    ruby -E UTF-8 /usr/share/openclash/openclash_proxy_multiport.rb merge "$1" || exit 1
    # OC_MULTIPORT_HOOK_END
  SH
  exits = text.to_enum(:scan, /^[ \t]*exit[ \t]+0[ \t]*$/).map { Regexp.last_match.begin(0) }
  if exits.empty?
    text += (text.end_with?("\n") ? '' : "\n") + block
  else
    text.insert(exits.last, block)
  end
end
File.binwrite(path, text)
RUBY
}
install_plugin() {
    for command in ruby curl uci; do
        command -v "$command" >/dev/null 2>&1 || fail "缺少 OpenClash 运行依赖：$command"
    done
    ruby -ryaml -e 'abort "Ruby 需要 2.7 或更高版本" if (RUBY_VERSION.split(".").first(2).map(&:to_i) <=> [2,7]) == -1; YAML.safe_load("{}")'
    [ -f "$CUSTOM" ] || fail "覆写脚本不存在：$CUSTOM"
    if [ -f "$LEGACY" ]; then
        grep -q '^-- OC_MULTIPORT_BACKEND_V' "$LEGACY" || fail "旧控制器无法识别：$LEGACY"
    fi
    files | while IFS='|' read -r source target; do
        [ -s "$BASE/$source" ] || fail "安装包缺少：$source"
    done
    ruby -c "$BASE/backend/openclash_proxy_multiport.rb" >/dev/null
    backup_current
    files | while IFS='|' read -r source target; do
        mkdir -p "$(dirname "$target")"
        cp "$BASE/$source" "$target"
        chmod 644 "$target"
    done
    hook install
    [ ! -f "$LEGACY" ] || rm -f "$LEGACY"
    refresh_luci
    echo '安装完成，请重新登录 LuCI，并按 Ctrl+F5 刷新。'
}
list_backups() {
    found_backup=false
    for directory in "$BACKUP_ROOT"/*; do
        [ -f "$directory/.complete" ] || continue
        kind=$(cat "$directory/.kind")
        case "$kind" in original) label='原版页面' ;; plugin) label='插件文件' ;; *) continue ;; esac
        printf '%s  %s\n' "$(basename "$directory")" "$label"
        found_backup=true
    done
    [ "$found_backup" = true ] || echo '暂无备份'
}
choose_backup() {
    backup_options=$(list_backups | LC_ALL=C sort -t '-' -k1,1n -k2,2n -k3,3n)
    if [ "$backup_options" = '暂无备份' ]; then echo '暂无可恢复的备份。'; return 2; fi
    select_item '恢复备份' "$backup_options" 1 backup || return 1
    choice=$(printf '%s\n' "$backup_options" | sed -n "${SELECTED}p" | awk '{print $1}')
    confirm_options=$(printf '确认恢复 %s\n取消' "$choice")
    select_item '确认恢复备份' "$confirm_options" 2 confirm || return 1
    [ "$SELECTED" = 1 ]
}
restore_backup() {
    choice=${1:-}
    if [ -z "$choice" ]; then
        choose_backup || return 0
    fi
    case "$choice" in ''|*[!0-9-]*) fail '备份目录名无效' ;; esac
    restore_dir=$BACKUP_ROOT/$choice
    [ -f "$restore_dir/.complete" ] && [ -s "$restore_dir/status.htm" ] || fail '备份不存在或不完整'
    restore_kind=$(cat "$restore_dir/.kind")
    case "$restore_kind" in original|plugin) ;; *) fail '备份类型无效' ;; esac
    if [ "$restore_kind" = original ] && [ -f "$CUSTOM" ]; then
        command -v ruby >/dev/null 2>&1 || fail '移除覆写步骤需要 OpenClash 的 Ruby'
    fi
    backup_current
    if [ "$restore_kind" = original ]; then
        [ ! -f "$CUSTOM" ] || hook remove
        files | while IFS='|' read -r source target; do
            if [ "$target" = "$STATUS" ]; then
                cp -p "$restore_dir/status.htm" "$target"
            else
                rm -f "$target"
            fi
        done
        if [ -f "$LEGACY" ] && grep -q '^-- OC_MULTIPORT_BACKEND_V' "$LEGACY"; then rm -f "$LEGACY"; fi
    else
        targets | while IFS= read -r target; do
            saved=$restore_dir/$(basename "$target")
            if [ -f "$saved" ]; then
                mkdir -p "$(dirname "$target")"; cp -p "$saved" "$target"
            else
                rm -f "$target"
            fi
        done
    fi
    refresh_luci
    echo "已恢复：$choice。请重新登录 LuCI，并按 Ctrl+F5 刷新。"
    echo '恢复仅回退文件；端口数据和当前内核运行配置保持不变。'
}

main_menu() {
    menu_options=$(printf '安装 / 更新\n恢复备份\n退出')
    while :; do
        menu_title=$(printf '安装与维护\nOpenClash：%s\n内核：%s' "${version:-未知}" "${core_version:-未找到内核}")
        select_item "$menu_title" "$menu_options" || return 0
        case "$SELECTED" in
            1) if sh "$BASE/install.sh" install; then :; else echo '安装未完成，请查看上方错误。'; fi ;;
            2)
                if choose_backup; then
                    if sh "$BASE/install.sh" restore "$choice"; then :; else echo '恢复未完成，请查看上方错误。'; fi
                else
                    [ "$?" != 1 ] || continue
                fi ;;
            3) return 0 ;;
        esac
        printf '\n  按 Enter 返回菜单…'
        read -r menu_pause || return 0
    done
}

case "${1:-menu}" in menu|install|restore) ;; *) echo "用法：sh $0 [install | restore [时间目录名]]"; exit 1 ;; esac
check_openclash
case "${1:-menu}" in
    menu) main_menu; exit 0 ;;
esac
LOCK_DIR=/tmp/openclash-multiport-install.lock
mkdir "$LOCK_DIR" 2>/dev/null || fail '另一个安装或恢复操作正在执行'
LOCK_HELD=$LOCK_DIR
case "$1" in
    install) install_plugin ;;
    restore) restore_backup "${2:-}" ;;
esac
