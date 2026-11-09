#!/bin/sh
# Run on the router as root. Backups contain deployed files, not proxy data.
set -eu
umask 077
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STATUS=/usr/lib/lua/luci/view/openclash/status.htm
CUSTOM=/etc/openclash/custom/openclash_custom_overwrite.sh
BACKUP_ROOT=${HOME:-/root}/openclash-multiport-back
LEGACY=/usr/lib/lua/luci/controller/oc_multiport.lua
REPOSITORY=https://github.com/Mozcy/openclash-multiport

fail() { echo "错误：$*" >&2; exit 1; }
TTY_STATE=''
LOCK_HELD=''
UPDATE_WORK=''
UPDATE_MUTATING=''
KEEP_UPDATE_WORK=''
restore_terminal() {
    if [ -n "$TTY_STATE" ]; then
        stty "$TTY_STATE" 2>/dev/null || :
        TTY_STATE=''
        printf '\033[?25h'
    fi
}
cleanup() {
    restore_terminal
    if [ -n "$UPDATE_MUTATING" ]; then
        echo '更新未完成，正在恢复更新前文件…' >&2
        if rollback_update; then
            echo '已恢复更新前的源码和部署文件。' >&2
        else
            KEEP_UPDATE_WORK=1
            echo "自动恢复未完成，请保留并检查：$UPDATE_WORK" >&2
        fi
    fi
    if [ -n "$UPDATE_WORK" ] && [ -z "$KEEP_UPDATE_WORK" ]; then
        case "$UPDATE_WORK" in "$BASE"/.oc-mp-update-*) rm -rf "$UPDATE_WORK" ;; esac
    fi
    [ -z "$LOCK_HELD" ] || rmdir "$LOCK_HELD" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

# BusyBox sh compatible: stty/dd handle keys without dialog or Bash read flags.
info_box() {
    # Count UTF-8 display cells in the C locale, so Chinese and long core versions align.
    box_columns=${COLUMNS:-120}
    if { [ -t 1 ] || [ -t 2 ]; } && command -v stty >/dev/null 2>&1; then
        box_size=$(stty size 2>/dev/null < /dev/tty) || box_size=''
        box_tty_columns=${box_size##* }
        case "$box_tty_columns" in ''|*[!0-9]*) ;; *) box_columns=$box_tty_columns ;; esac
    fi
    case "$box_columns" in ''|*[!0-9]*) box_columns=120 ;; esac
    [ "${#box_columns}" -le 4 ] || box_columns=120
    [ "$box_columns" -ge 24 ] || box_columns=24
    [ "$box_columns" -le 120 ] || box_columns=120
    LC_ALL=C awk -v columns="$box_columns" -v align="${1:-box}" '
        function rule( i) { printf "  +"; for (i=0;i<content+2;i++) printf "-"; print "+" }
        function row(s,w, pad) {
            if (align=="right") {
                for (pad=w;pad<content;pad++) printf " "
                printf "%s",s
                return
            }
            printf "  | "
            printf "%s",s
            for (pad=w;pad<content;pad++) printf " "
            print " |"
        }
        BEGIN {content=columns-(align=="right" ? 2 : 8);if(align!="right") rule()}
        {
            gsub(/[\001-\037\177]/, "")
            line=""; cells=0
            for (i=1;i<=length($0);) {
                c=substr($0,i,1); bytes=1; size=1
                if (c ~ /[\300-\337]/) bytes=2
                else if (c ~ /[\340-\357]/) {bytes=3;size=2}
                else if (c ~ /[\360-\367]/) {bytes=4;size=2}
                if (cells+size>content) {row(line,cells);if(align=="right") printf "\n";line="";cells=0}
                line=line substr($0,i,bytes);cells+=size;i+=bytes
            }
            row(line,cells)
        }
        END {if(align!="right") rule()}'
}
valid_version() {
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}
version_newer() {
    LC_ALL=C awk -v candidate="$1" -v reference="$2" 'BEGIN {
        sub(/^v/,"",candidate);sub(/^v/,"",reference);split(candidate,a,".");split(reference,b,".")
        for(i=1;i<=3;i++) {if(a[i]+0>b[i]+0) exit 0;if(a[i]+0<b[i]+0) exit 1} exit 1
    }'
}
source_version() {
    detected=''
    if [ -f "$1/oc-proxy-multiport.js" ]; then
        detected=$(sed -n '1s|^// OpenClash Multiport \(v[0-9.]*\)$|\1|p' "$1/oc-proxy-multiport.js")
    fi
    if ! valid_version "$detected" && [ -f "$1/.oc-mp-release" ]; then
        detected=$(cat "$1/.oc-mp-release")
    fi
    if valid_version "$detected"; then printf '%s\n' "$detected"; else echo unknown; fi
}
installed_version() {
    deployed=/usr/lib/lua/luci/controller/openclash_proxy_multiport.lua
    detected=''
    [ ! -f "$deployed" ] || detected=$(sed -n 's/^-- OC_MULTIPORT_BACKEND_VERSION: \(v[0-9.]*\)$/\1/p' "$deployed")
    if valid_version "$detected"; then echo "$detected"
    elif [ -f "$deployed" ] || grep -q 'id="oc-multiport"' "$STATUS"; then echo '已安装（旧版）'
    else echo '未安装'; fi
}
picker_rows() {
    printf '%s\n' "$picker_options" | awk -v selected="$SELECTED" -v start="${2:-1}" -v only="${3:-0}" -v color="${1:-0}" -v view="$picker_view" '
        (!only || NR == only) && (!color || (NR >= start && NR < start + 10)) {
            text = $0
            if (view == "backup") {
                split($1, stamp, "-")
                date = substr(stamp[1],1,4) "-" substr(stamp[1],5,2) "-" substr(stamp[1],7,2)
                time = substr(stamp[2],1,2) ":" substr(stamp[2],3,2) ":" substr(stamp[2],5,2)
                suffix = stamp[3] == "" ? "" : "#" stamp[3]
                text = sprintf("%s  %s  %-4s [%s]", date, time, suffix, $2)
            }
            if (color && NR == selected) printf "  \033[1;36m> %2d  %s\033[0m\n", NR, text
            else if (color) printf "    %2d  %s\n", NR, text
            else printf "    %2d. %s\n", NR, text
        }'
}
picker_heading() {
    if [ "$picker_view" = menu ]; then printf '%s\n' "$picker_title"
    else printf 'OpenClash Multiport\n\n%s\n' "$picker_title"; fi | info_box
}
picker_footer() {
    printf '  \033[36m[ ↑↓ 选择 ]\033[0m   \033[36m[ Enter 确认 ]\033[0m   \033[36m[ Esc 返回 ]\033[0m   \033[90m%s / %s\033[0m\033[K\n' "$SELECTED" "$picker_count"
}
picker_redraw_row() {
    printf '\0338'
    picker_offset=$(($1 - picker_start))
    [ "$picker_offset" = 0 ] || printf '\033[%sB' "$picker_offset"
    printf '\r%s\033[K' "$(picker_rows 1 "$picker_start" "$1")"
}
picker_page_rows() {
    picker_rows 1 "$picker_start" | awk -v slots="$picker_slots" '
        {printf "\r%s\033[K\n",$0}
        END {for(i=NR;i<slots;i++) printf "\r\033[K\n"}'
}
render_picker() {
    picker_start=$(((SELECTED - 1) / 10 * 10 + 1))
    [ -z "$picker_drawn" ] || [ "$picker_previous" != "$SELECTED" ] || return 0
    # Send one buffered update. After the first frame, keep the header untouched.
    picker_frame=$(
        if [ -z "$picker_drawn" ]; then
            printf '\033[2J\033[H\n'
            picker_heading || exit 1
            if [ "$picker_view" = backup ]; then
                printf '\n  \033[90m共 %s 个备份 · 按时间从旧到新\033[0m\n' "$picker_count"
            elif [ "$picker_view" = confirm ]; then
                printf '\n  \033[90m仅恢复文件，端口数据和当前运行配置保留。\033[0m\n'
            fi
            printf '\n'
            picker_page_rows
            printf '\n'
            picker_footer
            # Save the list anchor after initial output has finished scrolling.
            printf '\033[%sA\r\0337\033[%sB' "$((picker_slots + 2))" "$((picker_slots + 2))"
        else
            if [ "$picker_page" != "$picker_start" ]; then
                printf '\0338'
                picker_page_rows
            else
                picker_redraw_row "$picker_previous"
                picker_redraw_row "$SELECTED"
            fi
            printf '\0338\033[%sB\r' "$((picker_slots + 1))"
            picker_footer
        fi
        # Keep the footer newline when command substitution trims trailing newlines.
        printf '\033[0m'
    ) || return 1
    printf '%s' "$picker_frame"
    picker_drawn=1; picker_previous=$SELECTED; picker_page=$picker_start
}
select_item() {
    picker_title=$1; picker_options=$2; SELECTED=${3:-1}; picker_view=${4:-menu}
    picker_count=$(printf '%s\n' "$picker_options" | wc -l | tr -d ' ')
    picker_drawn=''; picker_previous=''; picker_page=''; picker_slots=$picker_count
    [ "$picker_slots" -le 10 ] || picker_slots=10
    if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && command -v stty >/dev/null 2>&1; then
        TTY_STATE=$(stty -g) || return 1
        stty -echo -icanon min 1 time 0 || { restore_terminal; return 1; }
        printf '\033[?25l'
        picker_enter=$(printf '\n.'); picker_enter=${picker_enter%.}
        while :; do
            render_picker || { restore_terminal; return 1; }
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
    printf '\n'; picker_heading
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
    if [ -x /etc/openclash/clash ]; then
        core_version=$(/etc/openclash/clash -v 2>/dev/null) || core_version='无法读取'
    else
        core_version='未找到 /etc/openclash/clash'
    fi
}
refresh_luci() {
    for cache in /tmp/luci-indexcache /tmp/luci-indexcache.*; do
        [ ! -f "$cache" ] || rm -f "$cache" || return 1
    done
    /etc/init.d/rpcd restart || return 1
}
backup_current() {
    kind=original
    if grep -q 'id="oc-multiport"' "$STATUS" ||
        [ -f /usr/lib/lua/luci/controller/openclash_proxy_multiport.lua ] ||
        [ -f /usr/share/openclash/openclash_proxy_multiport.rb ] ||
        { [ -f "$LEGACY" ] && grep -q '^-- OC_MULTIPORT_BACKEND_V' "$LEGACY"; }; then
        kind=plugin
    fi
    mkdir -p "$BACKUP_ROOT" || return 1
    chmod 700 "$BACKUP_ROOT" || return 1
    stamp=$(date '+%Y%m%d-%H%M%S')
    snapshot=$BACKUP_ROOT/$stamp
    suffix=0
    while [ -e "$snapshot" ]; do
        suffix=$((suffix + 1)); snapshot=$BACKUP_ROOT/$stamp-$suffix
    done
    mkdir "$snapshot" || return 1
    printf '%s\n' "$kind" > "$snapshot/.kind" || return 1
    if [ "$kind" = original ]; then
        cp -p "$STATUS" "$snapshot/status.htm" || return 1
    else
        targets | while IFS= read -r target; do
            [ ! -f "$target" ] || cp -p "$target" "$snapshot/$(basename "$target")" || exit 1
        done || return 1
    fi
    : > "$snapshot/.complete" || return 1
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
    ruby -ryaml -e 'abort "Ruby 需要 2.7 或更高版本" if (RUBY_VERSION.split(".").first(2).map(&:to_i) <=> [2,7]) == -1; YAML.safe_load("{}")' || return 1
    [ -f "$CUSTOM" ] || fail "覆写脚本不存在：$CUSTOM"
    if [ -f "$LEGACY" ]; then
        grep -q '^-- OC_MULTIPORT_BACKEND_V' "$LEGACY" || fail "旧控制器无法识别：$LEGACY"
    fi
    files | while IFS='|' read -r source target; do
        [ -s "$BASE/$source" ] || fail "安装包缺少：$source"
    done || return 1
    ruby -c "$BASE/backend/openclash_proxy_multiport.rb" >/dev/null || return 1
    backup_current || return 1
    files | while IFS='|' read -r source target; do
        mkdir -p "$(dirname "$target")" || exit 1
        cp "$BASE/$source" "$target" || exit 1
        chmod 644 "$target" || exit 1
    done || return 1
    hook install || return 1
    [ ! -f "$LEGACY" ] || rm -f "$LEGACY" || return 1
    refresh_luci || return 1
    echo '安装完成，请重新登录 LuCI，并按 Ctrl+F5 刷新。'
}
source_item() {
    # Source snapshots must never contain older snapshots or the active download.
    case "$(basename "$1")" in
        .git|node_modules|openclash-multiport-back|openclash-multiport-v[0-9]*|openclash-multiport-unknown*|.oc-mp-update-*) return 1 ;;
    esac
    return 0
}
backup_source() {
    source_label=$(source_version "$BASE")
    [ "$source_label" != unknown ] || source_label=unknown-$(date '+%Y%m%d-%H%M%S')
    SOURCE_BACKUP=$BASE/openclash-multiport-$source_label
    source_suffix=0
    while [ -e "$SOURCE_BACKUP" ] || [ -L "$SOURCE_BACKUP" ]; do
        source_suffix=$((source_suffix + 1))
        SOURCE_BACKUP=$BASE/openclash-multiport-$source_label-$source_suffix
    done
    mkdir "$SOURCE_BACKUP" || return 1
    for item in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        if source_item "$item"; then cp -pR "$item" "$SOURCE_BACKUP/" || return 1; fi
    done
    printf '%s\n' "$source_label" > "$SOURCE_BACKUP/.oc-mp-source-backup" || return 1
    echo "源码已完整备份：$SOURCE_BACKUP"
}
download_release() {
    release_url=$(curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 45 \
        --output /dev/null --write-out '%{url_effective}' "$REPOSITORY/releases/latest") || fail '无法获取最新正式版本，请检查网络或 GitHub 访问情况'
    case "$release_url" in "$REPOSITORY/releases/tag/"*) latest=${release_url##*/} ;; *) fail '未找到有效的 GitHub 正式版本' ;; esac
    valid_version "$latest" || fail '发布标签须为 v主版本.次版本.修订号，例如 v1.0.1'
    current=$(source_version "$BASE")
    deployed_version=$(installed_version)
    printf '当前源码：%s\n已安装版本：%s\n最新正式版：%s\n' "$current" "$deployed_version" "$latest"
    if valid_version "$deployed_version" && version_newer "$deployed_version" "$latest"; then
        echo '已安装版本比最新正式版更新，已跳过，避免降级。'
        return 2
    fi
    if [ "$current" != unknown ]; then
        if ! version_newer "$latest" "$current"; then
            echo '当前源码已是最新版本或更新的开发版本，无需更新。'
            return 2
        fi
    fi
    UPDATE_WORK=$(mktemp -d "$BASE/.oc-mp-update-XXXXXX") || fail '无法创建更新临时目录，请检查权限和剩余空间'
    echo "正在下载 $latest …"
    curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 \
        --output "$UPDATE_WORK/release.tar.gz" \
        "https://codeload.github.com/Mozcy/openclash-multiport/tar.gz/refs/tags/$latest" || fail '下载失败，当前文件未修改'
    tar -tzf "$UPDATE_WORK/release.tar.gz" > "$UPDATE_WORK/archive.list" || fail '下载包无法读取'
    LC_ALL=C awk '
        /^\// || /\\/ || /[[:cntrl:]]/ {exit 1}
        {n=split($0,a,"/");if(NR==1) root=a[1];if(a[1]!=root || root=="") exit 1
         for(i=1;i<=n;i++) if(a[i]==".." || a[i]==".") exit 1
         if(a[2]==".git" || a[2] ~ /^\.oc-mp-update-/ || a[2] ~ /^openclash-multiport-(v[0-9]|unknown|back)/) exit 1}
        END {if(NR==0) exit 1}' "$UPDATE_WORK/archive.list" || fail '更新包目录结构不合法'
    tar -tvzf "$UPDATE_WORK/release.tar.gz" > "$UPDATE_WORK/archive.types" || fail '无法检查更新包文件类型'
    LC_ALL=C awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' "$UPDATE_WORK/archive.types" || fail '更新包包含不支持的链接或特殊文件'
    mkdir "$UPDATE_WORK/unpacked" || fail '无法创建解压目录'
    tar -xzf "$UPDATE_WORK/release.tar.gz" -C "$UPDATE_WORK/unpacked" || fail '解压失败，当前文件未修改'
    archive_root=$(sed -n '1s|/.*||p' "$UPDATE_WORK/archive.list")
    RELEASE_DIR=$UPDATE_WORK/unpacked/$archive_root
    [ -s "$RELEASE_DIR/SHA256SUMS" ] || fail '更新包缺少 SHA256SUMS，当前文件未修改'
    LC_ALL=C awk '
        {hash=substr($0,1,64);path=substr($0,67)
         if(length(hash)!=64 || hash ~ /[^0-9a-f]/ || substr($0,65,2)!="  " || path=="" || path ~ /^\// || path ~ /\\/ || path ~ /[[:cntrl:]]/) exit 1
         n=split(path,a,"/");for(i=1;i<=n;i++) if(a[i]==".." || a[i]=="." || a[i]=="") exit 1}
        END {if(NR==0) exit 1}' "$RELEASE_DIR/SHA256SUMS" || fail '更新包校验清单格式错误'
    (files | cut -d '|' -f 1; echo install.sh) | while IFS= read -r required; do
        [ -s "$RELEASE_DIR/$required" ] || exit 1
        awk -v name="$required" 'substr($0,67)==name {found=1} END {exit !found}' "$RELEASE_DIR/SHA256SUMS" || exit 1
    done || fail '更新包缺少必要源码或对应校验值'
    (cd "$RELEASE_DIR" && sha256sum -c SHA256SUMS) || fail '更新包 SHA256 校验失败，当前文件未修改'
    sh -n "$RELEASE_DIR/install.sh" || fail '更新包安装脚本语法错误'
    ruby -c "$RELEASE_DIR/backend/openclash_proxy_multiport.rb" >/dev/null || fail '更新包 Ruby 语法错误'
    package_version=$(source_version "$RELEASE_DIR")
    [ "$package_version" = unknown ] || [ "$package_version" = "$latest" ] || fail '源码版本与发布标签不一致'
}
save_deployed() {
    mkdir "$UPDATE_WORK/deployed" || return 1
    targets | while IFS= read -r target; do
        [ ! -L "$target" ] || exit 1
        [ ! -e "$target" ] || { [ -f "$target" ] && cp -p "$target" "$UPDATE_WORK/deployed/$(basename "$target")"; } || exit 1
    done || return 1
}
replace_source() {
    mkdir "$UPDATE_WORK/previous" || return 1
    for item in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        if source_item "$item"; then mv "$item" "$UPDATE_WORK/previous/" || return 1; fi
    done
    : > "$UPDATE_WORK/source-ready" || return 1
    for item in "$RELEASE_DIR"/* "$RELEASE_DIR"/.[!.]* "$RELEASE_DIR"/..?*; do
        [ -e "$item" ] || continue
        cp -pR "$item" "$BASE/" || return 1
    done
    printf '%s\n' "$latest" > "$BASE/.oc-mp-release" || return 1
}
rollback_update() {
    if [ -f "$UPDATE_WORK/source-ready" ]; then
        mkdir -p "$UPDATE_WORK/failed" || return 1
        for item in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            if source_item "$item"; then mv "$item" "$UPDATE_WORK/failed/" || return 1; fi
        done
    fi
    for item in "$UPDATE_WORK/previous"/* "$UPDATE_WORK/previous"/.[!.]* "$UPDATE_WORK/previous"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        mv "$item" "$BASE/" || return 1
    done
    if [ -f "$UPDATE_WORK/deploying" ]; then
        targets | while IFS= read -r target; do
            saved=$UPDATE_WORK/deployed/$(basename "$target")
            if [ -f "$saved" ]; then cp -p "$saved" "$target" || exit 1
            else rm -f "$target" || exit 1; fi
        done || return 1
        refresh_luci || return 1
    fi
    UPDATE_MUTATING=''
}
update_online() {
    for command in curl ruby tar sha256sum mktemp; do
        command -v "$command" >/dev/null 2>&1 || fail "缺少更新工具：$command"
    done
    if download_release; then :
    else update_status=$?; [ "$update_status" = 2 ] && return 0; return "$update_status"; fi
    backup_source || fail '源码备份失败，当前文件未修改'
    save_deployed || fail '无法保存当前部署文件，当前文件未修改'
    UPDATE_MUTATING=1
    replace_source || fail '替换源码失败，将恢复更新前文件'
    : > "$UPDATE_WORK/deploying" || fail '无法记录更新状态'
    # Keep the current process and its lock while installing the verified new files.
    install_plugin || fail '安装失败，将恢复更新前文件'
    UPDATE_MUTATING=''
    printf '更新完成\n当前版本：%s\n源码备份：%s\n' "$latest" "$SOURCE_BACKUP"
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

menu_result() {
    printf '\033[2J\033[H\n\n'
    printf '%s\n' "$1" | info_box
}
run_menu_action() {
    action_label=$1; shift
    menu_result "$action_label，正在执行，请稍候…"
    # Use a separate shell so update rollback/cleanup traps retain their own state.
    if action_output=$(sh "$BASE/install.sh" "$@" 2>&1); then
        [ -n "$action_output" ] || action_output='操作完成。'
    else
        action_output=$(printf '%s\n%s未完成，请检查上述错误。' "$action_output" "$action_label")
    fi
    menu_result "$action_output"
}
main_menu() {
    menu_options=$(printf '本地安装 / 更新\n在线更新\n恢复备份\n退出')
    while :; do
        menu_title=$(printf 'OpenClash Multiport  最新版本：%s  安装版本：%s\n\nOpenClash：%s\n内核：%s' "$(source_version "$BASE")" "$(installed_version)" "${version:-未知}" "${core_version:-未找到内核}")
        select_item "$menu_title" "$menu_options" || return 0
        case "$SELECTED" in
            1) run_menu_action '本地安装 / 更新' install ;;
            2) run_menu_action '在线更新' update ;;
            3)
                if [ "$(list_backups)" = '暂无备份' ]; then
                    menu_result '暂无可恢复的备份。'
                elif choose_backup; then
                    run_menu_action '恢复备份' restore "$choice"
                else
                    [ "$?" != 1 ] || continue
                fi ;;
            4) return 0 ;;
        esac
        printf '\n'
        printf '%s' '按 [ Enter ] 返回菜单' | info_box right
        read -r menu_pause || return 0
    done
}

case "${1:-menu}" in menu|install|update|restore) ;; *) echo "用法：sh $0 [install | update | restore [时间目录名]]"; exit 1 ;; esac
check_openclash
case "${1:-menu}" in
    menu) main_menu; exit 0 ;;
esac
LOCK_DIR=/tmp/openclash-multiport-install.lock
mkdir "$LOCK_DIR" 2>/dev/null || fail '另一个安装或恢复操作正在执行'
LOCK_HELD=$LOCK_DIR
case "$1" in
    install) install_plugin ;;
    update) update_online ;;
    restore) restore_backup "${2:-}" ;;
esac
