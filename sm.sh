#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# MIT License
#
# Copyright (c) 2026 smmya
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ============================================================================
#  sm.sh - Supervisor Manager (interactive shell, menu-driven)
#  参考 mdserver-web / 宝塔 supervisor 插件功能集，纯 bash 实现。
#  覆盖：安装、开机自启、状态看板、增删改查、启停重启、日志、配置重载。
#  v1.3.0：首页直接渲染进程状态看板（不再需要单独进"查看状态"）。
#  v1.3.1：编辑配置加备份 + 改动检测 + 重载闭环；修复 reread 失败仍报"重载完成"。
#  v1.3.2：配置定位改以主配置 [include] files 为准——修复 include 指向别处
#          （如 RHEL 的 /etc/supervisord.d/*.ini）时"编辑/删除"列表全空的问题。
#  v1.4.0：启动时自动切到 UTF-8 locale（应对 sudo 清空 LANG）；界面按"显示宽度"
#          排版，中文表头、分隔线、日志前缀在任意 locale 下都对齐。
# ============================================================================

# 注意：交互式菜单工具不使用 set -e。原因：
# 1. 子命令（supervisorctl）失败会让脚本意外退出，破坏菜单循环；
# 2. ui_menu 用命令替换时，子 shell 内任何失败都会让 $() 返回空，触发死循环。
# 改为各 action 内部显式 return/error 处理。
set -uo pipefail

SM_VERSION="1.5.0"

# 配置默认值（可被环境变量覆盖）
SM_CONF_DIR="${SM_CONF_DIR:-/etc/supervisor/conf.d}"
_SM_CONF_EXPLICIT=0
[[ -n "${SM_MAIN_CONF:-}" ]] && _SM_CONF_EXPLICIT=1
SM_MAIN_CONF="${SM_MAIN_CONF:-/etc/supervisor/supervisord.conf}"
_SM_CONF_AMBIGUOUS=0
_SM_DAEMON_PID=""
SM_LOG_DIR="${SM_LOG_DIR:-/var/log/supervisor}"
SM_RUN_DIR="${SM_RUN_DIR:-/var/run/supervisor}"
# 编辑前的自动备份目录（宁可多占几 KB，也别让改坏配置变成不可逆事故）
SM_BACKUP_DIR="${SM_BACKUP_DIR:-/var/backups/supervisor-manager}"
# 界面总宽：标题线、分隔线、状态表都按这个值排版（终端常见 80 列，68 留有余量）
# 未显式指定时默认 68，并在终端更窄时自动收窄（见 _fit_width），避免折行破坏对齐
_SM_WIDTH_AUTO=0
if [[ -z "${SM_WIDTH:-}" ]]; then
    SM_WIDTH=68
    _SM_WIDTH_AUTO=1
fi
# 状态表各列宽度（之和 + 缩进 2 + 列间距 6 = SM_WIDTH）
_SM_W_NAME=26; _SM_W_STATE=11; _SM_W_PID=7; _SM_W_UP=16

# ui_menu 选中值的全局变量（避免命令替换陷阱）
_SM_MENU_CHOICE=""
# locale 自适应后待显示的一次性提示（进菜单首屏时打印后清空）
_SM_LOCALE_NOTE=""
# 字节值查找表 + 宽度计算自检结果
_SM_BYTES=""
_SM_DW_OK=0
_SM_TESTING=0
_SM_PAD=""        # _pad_c / _rule 的输出落点（避免用 $( ) 取结果而 fork）

# ---------------------- 颜色 ----------------------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"; C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
    C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_GRAY="\033[90m"; C_BOLD="\033[1m"
    C_BG_BLUE="\033[44m"
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
    C_CYAN=""; C_GRAY=""; C_BOLD=""; C_BG_BLUE=""
fi

# ============================================================================
#  显示宽度对齐（与系统 locale 无关）
#
#  为什么不能用 printf 的 %-Ns 给中文补齐——实测同一个 %-8s 作用于「名称」：
#     LC_ALL=C            → 补 2 个空格（按字节，6 字节）
#     LC_ALL=zh_CN.UTF-8  → 补 6 个空格（按字符，2 个字符）
#     正确值              → 4 个空格（终端里占 4 列）
#  也就是说没有任何 locale 能让 printf 自动对齐中文。唯一可靠的做法是按
#  "终端显示宽度"手工补齐：CJK / 全角字符 2 列，其余 1 列，ANSI 转义 0 列。
#
#  实现刻意不依赖 locale：在 C locale 的子 shell 里逐字节还原码点，所以无论
#  脚本跑在 C / C.UTF-8 / zh_CN.UTF-8，排版结果都一样。
# ============================================================================

# 字节值查找表：第 N 个字节的值就是 N（1..255），用于把单个字节还原成数值
_sm_bytes_init() {
    local fmt="" i o
    for ((i = 1; i <= 255; i++)); do
        printf -v o '%03o' "$i"
        fmt+="\\$o"
    done
    _SM_BYTES=$(printf "$fmt")
}

# 取单个字节的数值，结果写入 _BV（不用 echo + $()，避免每个字节 fork 一次）
_bv() {
    local pre
    pre="${_SM_BYTES%%"$1"*}"
    _BV=$(( ${#pre} + 1 ))
    (( _BV > 255 )) && _BV=0
}

# 按显示宽度右补空格；超宽则截断并以 .. 结尾。必须在 LC_ALL=C 下调用
# 结果写入变量 _SM_PAD（不打印）：一次 $( ) 就是一次 fork，表格每行要补 4 格，
# 走 stdout 的话几十个进程就是上百次 fork，慢的机器上首屏要等好几秒
_pad_c() {
    local s want i=0 n dw=0 pre ch b b1 b2 cp len wide j k acc out w
    s="$1"; want="$2"; n=${#s}
    # 自检未通过时退回普通 printf（行为与旧版一致，至少不会更糟）
    # _SM_TESTING=1 时强制走完整算法——自检本身就是在这个标志下进行的，
    # 否则自检测到的永远是回退路径的结果，宽度计算永远启用不了
    if (( ! (_SM_DW_OK || _SM_TESTING) )); then
        _SM_PAD="$s"
        (( n < want )) && printf -v _SM_PAD '%s%*s' "$s" $((want - n)) ''
        return 0
    fi
    local -a cs=() ws=()
    while (( i < n )); do
        ch="${s:i:1}"
        pre="${_SM_BYTES%%"$ch"*}"; b=$(( ${#pre} + 1 )); (( b > 255 )) && b=0
        # ANSI 转义序列：ESC [ ... 终止字节(0x40-0x7E)，整体 0 列
        if (( b == 27 )); then
            if [[ "${s:i+1:1}" == "[" ]]; then
                j=$((i + 2))
                while (( j < n )); do
                    _bv "${s:j:1}"; j=$((j + 1))
                    (( _BV >= 0x40 && _BV <= 0x7E )) && break
                done
            else
                j=$((i + 2))
            fi
            cs+=("${s:i:j-i}"); ws+=(0); i=$j; continue
        fi
        # 控制字符、游离的续字节：0 列
        if (( b < 0x20 || (b >= 0x80 && b < 0xC0) )); then
            cs+=("$ch"); ws+=(0); i=$((i + 1)); continue
        fi
        # 由首字节判断字符长度，并还原 Unicode 码点
        if (( b < 0x80 )); then
            len=1; cp=$b
        elif (( b < 0xE0 )); then
            len=2; _bv "${s:i+1:1}"; b1=$_BV
            cp=$(( ((b & 0x1F) << 6) | (b1 & 0x3F) ))
        elif (( b < 0xF0 )); then
            len=3; _bv "${s:i+1:1}"; b1=$_BV; _bv "${s:i+2:1}"; b2=$_BV
            cp=$(( ((b & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F) ))
        else
            len=4; cp=0x20000       # 4 字节（emoji 等）一律按 2 列
        fi
        wide=0
        # 注意：(( )) 内部不能写 # 注释——# 在算术上下文里是进制分隔符（如 16#ff），
        # 写了就是语法错误，而且整段表达式静默失效
        # 判定"占 2 列"的范围：
        #   4 字节字符（emoji 等）、谚文字母 1100-115F、CJK 部首与标点 2E80-303E、
        #   假名与兼容字符 3041-33FF、扩展 A 3400-4DBF、CJK 统一表意 4E00-9FFF、
        #   彝文 A000-A4CF、谚文音节 AC00-D7A3、兼容表意 F900-FAFF、
        #   竖排形式 FE10-FE19 / FE30-FE6F、全角 ASCII 与括号 FF00-FF60、FFE0-FFE6
        if (( len == 4
              || (cp >= 0x1100 && cp <= 0x115F)
              || (cp >= 0x2E80 && cp <= 0x303E)
              || (cp >= 0x3041 && cp <= 0x33FF)
              || (cp >= 0x3400 && cp <= 0x4DBF)
              || (cp >= 0x4E00 && cp <= 0x9FFF)
              || (cp >= 0xA000 && cp <= 0xA4CF)
              || (cp >= 0xAC00 && cp <= 0xD7A3)
              || (cp >= 0xF900 && cp <= 0xFAFF)
              || (cp >= 0xFE10 && cp <= 0xFE19)
              || (cp >= 0xFE30 && cp <= 0xFE6F)
              || (cp >= 0xFF00 && cp <= 0xFF60)
              || (cp >= 0xFFE0 && cp <= 0xFFE6) )); then
            wide=1
        fi
        # 不用 ws[-1]：负下标要 bash 4.3+，CentOS 7 的 4.2 会报 bad array subscript
        w=$(( wide ? 2 : 1 ))
        ws+=( "$w" )
        dw=$((dw + w))
        cs+=("${s:i:len}")
        i=$((i + len))
    done

    if (( dw <= want )); then
        _SM_PAD="$s"
        (( dw < want )) && printf -v _SM_PAD '%s%*s' "$s" $((want - dw)) ''
        return 0
    fi
    # 超宽截断：保留 want-2 列，结尾用 ASCII 的 ..（省略号 … 是"宽度不确定"字符，不能用）
    acc=0; out=""
    for k in "${!cs[@]}"; do
        (( acc + ws[k] > want - 2 )) && break
        out+="${cs[k]}"
        acc=$((acc + ws[k]))
    done
    _SM_PAD="${out}.."
}

# 对外接口：在 C locale 的子 shell 里补齐并输出到 stdout，调用方无需关心当前 locale
# 用法：_pad "文本" 宽度        直接输出（只在自检等少量场景用；批量渲染请用 _pad_c 读 _SM_PAD）
_pad() {
    ( LC_ALL=C; _pad_c "$@"; printf '%s' "$_SM_PAD" )
}

# 生成 n 个指定字符组成的横线（无 fork）
# 生成 n 个指定字符组成的横线，结果写入 _SM_PAD（无 fork）
_rule() {
    local s
    printf -v s '%*s' "$1" ''
    _SM_PAD="${s// /${2:--}}"
}

# 启动时自检：任一用例不符就关闭宽度计算，退回旧行为
_sm_width_selftest() {
    local e=$'\033'
    _SM_DW_OK=0
    _SM_TESTING=1
    [[ $( (LC_ALL=C; echo ${#_SM_BYTES}) ) -eq 255 ]] || return 1
    [[ "$(_pad "中" 4)"              == "中  "                 ]] || return 1
    [[ "$(_pad "名称" 8)"            == "名称    "             ]] || return 1
    [[ "$(_pad "ab" 4)"              == "ab  "                 ]] || return 1
    [[ "$(_pad "${e}[31m中${e}[0m" 4)" == "${e}[31m中${e}[0m  " ]] || { _SM_TESTING=0; return 1; }
    [[ "$(_pad "一个很长很长的进程名字超过限制" 10)" == "一个很长.." ]] || { _SM_TESTING=0; return 1; }
    _SM_TESTING=0
    _SM_DW_OK=1
}

# 终端比默认宽度窄时收窄界面：只动"名称"列（最宽、也最适合被截断），
# 其余三列装的是状态/PID/时长，再窄就放不下了。显式设置了 SM_WIDTH 则完全尊重用户。
_fit_width() {
    (( _SM_WIDTH_AUTO )) || return 0
    local cols="${COLUMNS:-}"
    # 非交互脚本里 COLUMNS 常常没有，退回 stty（stdin 是 tty 时才问得到）
    if [[ -z "$cols" || "$cols" == "80" ]] && [[ -t 0 ]]; then
        cols=$(stty size 2>/dev/null | awk '{print $2}')
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || return 0
    (( cols >= SM_WIDTH )) && return 0
    (( cols < 44 )) && cols=44          # 再窄就没有可读性可言了，保底 44
    _SM_W_NAME=$(( _SM_W_NAME - (SM_WIDTH - cols) ))
    ((_SM_W_NAME < 6)) && _SM_W_NAME=6
    SM_WIDTH=$(( 2 + _SM_W_NAME + 2 + _SM_W_STATE + 2 + _SM_W_PID + 2 + _SM_W_UP ))
    return 0
}

# ============================================================================
#  locale 自适应
#
#  `sudo` 默认 env_reset 会清掉 LANG/LC_*，脚本于是跑在 C locale：bash 把一个
#  汉字当成 3 个字节处理，`read` 读进来的中文也可能被切坏。进菜单前先探测，
#  不是 UTF-8 就切到系统里可用的 UTF-8 locale。
#
#  能改的：本脚本进程及其子进程（bash / awk / vim / supervisorctl）的 locale。
#  改不了的：终端软件自身的解码方式（Xshell、PuTTY 的"编码"是客户端设置），
#           以及脚本退出后的父 shell。这两点只能靠提示。
# ============================================================================

# 用 bash 自己的字符计数判定：UTF-8 下「中」是 1 个字符，C locale 下是 3 个字节
_locale_is_utf8() {
    local probe="中"
    (( ${#probe} == 1 ))
}

# 在子 shell 里试一个候选 locale 是否真的生效（不污染当前环境）
_locale_works() {
    # 子 shell 里赋值不会外泄，所以不用 local（local 在非函数上下文的子 shell 里会报错）
    ( LC_ALL="$1"; p="中"; (( ${#p} == 1 )) ) 2>/dev/null
}

_ensure_utf8_locale() {
    # SM_LOCALE=0 关闭自适应；SM_LOCALE=<name> 指定要用哪个 locale
    local opt="${SM_LOCALE:-1}"
    [[ "$opt" == "0" ]] && return 0
    if [[ "$opt" == "1" ]] && _locale_is_utf8; then
        return 0
    fi

    local -a cands=()
    local c pick=""
    [[ "$opt" != "1" ]] && cands+=("$opt")
    # LANG 原本是非 UTF-8 的 locale（如 zh_CN.GBK）时，优先同语言的 UTF-8 变体。
    # 注意判断要用完整的 LANG：先截掉编码再判断，会把 en_US.UTF-8 也误判成
    # "非 UTF-8"，从而让 en_US.UTF-8 抢到 C.UTF-8 前面
    if [[ -n "${LANG:-}" && "$LANG" != *[Uu][Tt][Ff]* ]]; then
        local lang="${LANG%%[@.]*}"
        [[ -n "$lang" ]] && cands+=("${lang}.UTF-8")
    fi
    cands+=(C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 zh_CN.UTF-8)

    for c in "${cands[@]}"; do
        if _locale_works "$c"; then
            pick="$c"; break
        fi
    done

    local before="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
    if [[ -z "$pick" ]]; then
        # 系统里一个可用的 UTF-8 locale 都没有：只能提示用户安装
        _SM_LOCALE_NOTE="  ${C_YELLOW}[WARN]${C_RESET}  系统中没有可用的 UTF-8 locale（当前: ${before}），中文可能显示异常\n${C_GRAY}        Debian/Ubuntu: apt install locales && dpkg-reconfigure locales\n        RHEL/CentOS:  localedef -c -f UTF-8 -i zh_CN zh_CN.UTF-8${C_RESET}"
        return 1
    fi

    # 有 LC_ALL 时只能整体覆盖（它的优先级最高）；否则只动 LC_CTYPE，
    # 这样消息语言等其他类别仍按用户原本的设置走，副作用最小
    if [[ -n "${LC_ALL:-}" ]]; then
        export LC_ALL="$pick"
    else
        export LC_CTYPE="$pick"
    fi
    if ! _locale_is_utf8; then
        _SM_LOCALE_NOTE="  ${C_YELLOW}[WARN]${C_RESET}  已设置 locale=$pick 但未生效，中文可能显示异常"
        return 1
    fi

    # 切换成功：告知一声。乱码的可能性来自终端软件而非 locale，所以再补一行英文
    # 不写"因为 sudo"之类的原因推测：原 locale 非 UTF-8 可能是 sudo、ssh 未传 LANG、
    # 或本来就没配，脚本无从判断，只陈述"从什么切到了什么"
    _SM_LOCALE_NOTE="  ${C_GRAY}[INFO]${C_RESET}  locale ${before} -> ${pick}（原 locale 非 UTF-8，已自动切换）\n        If the text below looks garbled, set your terminal encoding to UTF-8.${C_RESET}"
    return 0
}

# ============================================================================
#  UI 工具函数
# ============================================================================

ui_line() {
    local char="${1:--}"; local len="${2:-$SM_WIDTH}"
    _rule "$len" "$char"; printf '%s\n' "$_SM_PAD"
}

ui_title() {
    echo
    echo -e "${C_BG_BLUE}${C_BOLD} $1 ${C_RESET}"
    ui_line '='
}

# 四种前缀统一成 7 个字符，后面的正文才能左对齐
ui_info()    { echo -e "${C_GREEN}[INFO]${C_RESET}  $*"; }
ui_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
ui_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
ui_success() { echo -e "${C_GREEN}${C_BOLD}[ OK ]${C_RESET}  $*"; }

# ui_ask prompt [default] -> 输出到 stdout
ui_ask() {
    local prompt="$1" default="${2:-}" input p
    if [[ -n "$default" ]]; then
        printf -v p "${C_BOLD}%s${C_RESET} [%s]: " "$prompt" "$default"
    else
        printf -v p "${C_BOLD}%s${C_RESET}: " "$prompt"
    fi
    read -r -p "$(echo -e "$p")" input || return 1
    if [[ -z "$input" && -n "$default" ]]; then echo "$default"
    else printf '%s\n' "$input"; fi
}

# ui_confirm "提示" [y|n] -> 0=是 1=否
ui_confirm() {
    local prompt="${1:-确认?}"; local default="${2:-y}"; local input
    while true; do
        if [[ "$default" == "y" ]]; then
            read -r -p "$(echo -e "${C_BOLD}${prompt}${C_RESET} [Y/n]: ")" input || return 1
            input="${input:-y}"
        else
            read -r -p "$(echo -e "${C_BOLD}${prompt}${C_RESET} [y/N]: ")" input || return 1
            input="${input:-n}"
        fi
        case "$input" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)    return 1 ;;
            *) echo "  请输入 y 或 n" ;;
        esac
    done
}

ui_pause() {
    echo
    # 仅在 stdin 是 tty 时阻塞等用户按键，否则直接返回
    if [ -t 0 ]; then
        read -r -N 1 -s -p "$(echo -e "${C_GRAY}按任意键继续...${C_RESET}")" _ || true
        echo
    fi
}

# 带 EOF 保护的输入：read 失败（Ctrl+D）时返回 1，调用方应中止流程
# 注意：提示信息必须走 stderr，否则会被调用方的 $(...) 捕获进变量
_ask_or_abort() {
    local val
    val=$(ui_ask "$@") || {
        echo >&2
        ui_warn "输入已中断（EOF），本次操作取消" >&2
        return 1
    }
    printf '%s' "$val"
}

# 把各种布尔写法统一为 supervisor 要求的 true/false
# 支持: y/yes/true/1/on -> true；n/no/false/0/off/空 -> false
_to_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        y|yes|true|1|on)  echo true ;;
        *)                echo false ;;
    esac
}

# 挑选编辑器：优先 $EDITOR；未设置则按常见编辑器探测
_pick_editor() {
    if [[ -n "${EDITOR:-}" ]]; then
        printf '%s' "$EDITOR"; return 0
    fi
    local c
    for c in vi vim nano emacs; do
        if command -v "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

# 打开编辑器：兼容 EDITOR 含参数的情况（如 EDITOR="vim -u NONE"）
# 返回编辑器退出码，找不到编辑器返回 127。
# 注意：这里不调用 ui_pause —— 暂停交给调用方，否则会出现连按两次的尴尬
_open_editor() {
    local file="$1"
    local ed
    ed=$(_pick_editor) || {
        ui_error "找不到编辑器（\$EDITOR / vi / vim / nano 均不可用）"
        ui_info "装一个（如 apt install vim）或设置 EDITOR=/path/to/editor"
        return 127
    }
    local -a ed_args
    read -r -a ed_args <<< "$ed"
    if [[ ${#ed_args[@]} -eq 0 ]]; then
        ui_error "EDITOR 为空，无法打开编辑器"
        return 127
    fi
    if ! command -v "${ed_args[0]}" >/dev/null 2>&1; then
        ui_error "找不到编辑器: ${ed_args[0]}"
        ui_info "可设置环境变量 EDITOR=vi（或 nano/vim）后重试"
        return 127
    fi
    "${ed_args[@]}" "$file"
}

# ============================================================================
#  配置文件定位
#  supervisor 到底加载哪些文件，由主配置的 [include] files 决定，而不是由本脚本
#  的 SM_CONF_DIR 决定。两者不一致时（典型：RHEL 系 files=/etc/supervisord.d/*.ini，
#  或进程直接写在 supervisord.conf 里），按 SM_CONF_DIR 扫描会得到空列表，
#  表现为"编辑进程配置什么也不显示"。以下函数统一以 include 为准。
# ============================================================================

# 提取主配置 [include] 段的 files 值（支持多行续行、空格分隔多个 glob）

# Reuse Supervisor's installed Python interpreter for its native parser.
_supervisor_python() {
    local sup line candidate
    local -a words=()
    sup=$(command -v supervisord) || return 1
    IFS= read -r line < "$sup" || return 1
    if [[ "$line" == '#!'* ]]; then
        read -r -a words <<< "${line:2}"
        candidate="${words[0]:-}"
        if [[ "${candidate##*/}" == env ]]; then candidate="${words[1]:-}"; fi
        if [[ -n "$candidate" ]] && "$candidate" -c 'import supervisor.options' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"; return 0
        fi
    fi
    for candidate in python3 python; do
        if "$candidate" -c 'import supervisor.options' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"; return 0
        fi
    done
    ui_error "找不到 Supervisor 自带的 Python 解析器" >&2
    return 1
}

_native_conf() {
    local py
    py=$(_supervisor_python) || return 1
    "$py" - "$@" <<'PY'
import glob
import os
import platform
import sys
from supervisor.options import UnhosedConfigParser, ServerOptions, ClientOptions, expand

mode, main = sys.argv[1:3]
main = os.path.abspath(main)
here = os.path.dirname(main)

def parser_for(path):
    p = UnhosedConfigParser()
    with open(path) as f:
        p.read_file(f)
    return p

try:
    if mode == 'validate':
        ServerOptions().realize(args=['-c', main])
        ClientOptions().realize(args=['-c', main, 'pid'])
    elif mode == 'log':
        c = ClientOptions()
        c.realize(args=['-c', main, 'pid'])
        p = c.getServerProxy().supervisor.getProcessInfo(sys.argv[3])
        value = p.get(sys.argv[4] + '_logfile', '')
        if value:
            print(value)
    else:
        p = parser_for(main)
        if mode == 'entities':
            for section in p.sections():
                print(section)
            sys.exit(0)
        patterns = []
        if p.has_section('include'):
            value = p.get('include', 'files')
            if '%(ENV_' in value:
                raise ValueError('ENV-dependent include requires explicit paths')
            value = expand(value, {'here': here, 'host_node_name': platform.node()}, 'include.files')
            patterns = [os.path.normpath(os.path.join(here, x)) for x in value.split()]
        if mode == 'patterns':
            for pattern in patterns:
                print(pattern)
        else:
            files = sorted(set(os.path.normpath(f) for pattern in patterns
                               for f in glob.glob(pattern) if os.path.isfile(f)))
            if mode == 'files':
                for f in files:
                    print(f)
            elif mode == 'names':
                for f in [main] + files:
                    for section in parser_for(f).sections():
                        if section.startswith(('program:', 'group:', 'eventlistener:', 'fcgi-program:')):
                            print(section.split(':', 1)[1])
            else:
                raise ValueError('unknown mode')
except Exception as e:
    print('配置解析失败: %s' % e, file=sys.stderr)
    sys.exit(1)
PY
}

_conf_include_patterns() { _native_conf patterns "${1:-$SM_MAIN_CONF}"; }
_conf_include_files() { _native_conf files "$SM_MAIN_CONF"; }
_conf_source_files() { _conf_include_files; }

_preferred_conf_target() {
    local name="$1" patterns pattern dir base candidate
    patterns=$(_conf_include_patterns) || return 1
    _SM_TARGET_FILE=""
    while IFS= read -r pattern; do
        [[ -n "$pattern" ]] || continue
        dir="${pattern%/*}"; base="${pattern##*/}"
        [[ "$dir" != *[\*\?\[]* && -d "$dir" ]] || continue
        [[ "$base" == *'*'* && "$base" != *[\?\[]* ]] || continue
        [[ "${base#*\*}" != *'*'* ]] || continue
        candidate="$dir/${base/\*/$name}"
        [[ "${candidate##*/}" == $base ]] || continue
        [[ ! -e "$candidate" && ! -L "$candidate" ]] || continue
        _SM_TARGET_FILE="$candidate"; return 0
    done <<< "$patterns"
    ui_error "无安全的 include 写入目标，或目标已存在"
    return 1
}

_program_exists() {
    local names
    names=$(_native_conf names "$SM_MAIN_CONF") || return 2
    grep -Fxq -- "$1" <<< "$names"
}

_lookup_key() {
    local stream
    case "$2" in stdout_logfile) stream=stdout;; stderr_logfile) stream=stderr;; *) return 1;; esac
    _native_conf log "$SM_MAIN_CONF" "$1" "$stream"
}

_daemon_config() {
    local pid="$1" arg prev=""
    while IFS= read -r -d '' arg; do
        case "$prev" in -c|--configuration) printf '%s\n' "$arg"; return 0;; esac
        case "$arg" in --configuration=*) printf '%s\n' "${arg#*=}"; return 0;; -c?*) printf '%s\n' "${arg:2}"; return 0;; esac
        prev="$arg"
    done < "/proc/$pid/cmdline"
    return 1
}

_discover_main_conf() {
    _SM_CONF_AMBIGUOUS=0; _SM_DAEMON_PID=""
    local proc arg pid path detected="" unit exec_line
    local -a pids=() candidates=()
    if (( _SM_CONF_EXPLICIT )); then
        [[ "$SM_MAIN_CONF" == /* ]] || SM_MAIN_CONF="$PWD/$SM_MAIN_CONF"
        return 0
    fi
    for proc in /proc/[0-9]*/comm; do
        { IFS= read -r arg < "$proc"; } 2>/dev/null || continue
        [[ "$arg" == supervisord ]] || continue
        pid="${proc#/proc/}"; pids+=("${pid%/comm}")
    done
    if (( ${#pids[@]} > 1 )); then _SM_CONF_AMBIGUOUS=1; return 1; fi
    if (( ${#pids[@]} == 1 )); then
        _SM_DAEMON_PID="${pids[0]}"
        detected=$(_daemon_config "$_SM_DAEMON_PID") || detected=""
        if [[ -n "$detected" ]]; then
            if [[ "$detected" != /* || ! -f "$detected" ]]; then _SM_CONF_AMBIGUOUS=1; return 1; fi
            SM_MAIN_CONF="$detected"; return 0
        fi
    fi
    if [[ -d /run/systemd/system ]]; then
        for unit in supervisor supervisord; do
            exec_line=$(systemctl show "$unit" -p ExecStart --value 2>/dev/null) || continue
            if [[ "$exec_line" =~ [[:space:]](-c|--configuration)[[:space:]]+([^[:space:]\;\}]+) ]]; then
                path="${BASH_REMATCH[2]}"
                [[ "$path" == /* && -f "$path" ]] && candidates+=("$path")
            fi
        done
    fi
    if (( ${#candidates[@]} == 0 )); then
        for path in /etc/supervisor/supervisord.conf /etc/supervisord.conf /usr/local/etc/supervisord.conf; do
            [[ -f "$path" ]] && candidates+=("$path")
        done
    fi
    if (( ${#candidates[@]} > 1 )); then
        for path in "${candidates[@]}"; do
            if [[ "$path" != "${candidates[0]}" && ! "$path" -ef "${candidates[0]}" ]]; then _SM_CONF_AMBIGUOUS=1; return 1; fi
        done
    fi
    if (( ${#candidates[@]} )); then SM_MAIN_CONF="${candidates[0]}"; fi
    if [[ -n "$_SM_DAEMON_PID" && ! -f "$SM_MAIN_CONF" ]]; then _SM_CONF_AMBIGUOUS=1; return 1; fi
    return 0
}

_conf_ready() {
    if (( _SM_CONF_AMBIGUOUS )); then
        ui_error "配置路径不明确；请显式设置 SM_MAIN_CONF" >&2; return 1
    fi
    [[ -f "$SM_MAIN_CONF" ]] || { ui_error "未找到主配置: $SM_MAIN_CONF" >&2; return 1; }
}

_svctl() {
    _conf_ready || return 1
    case "${1:-}" in
        pid|status)
            if command -v timeout >/dev/null 2>&1; then
                timeout 5 supervisorctl -c "$SM_MAIN_CONF" "$@"; return $?
            fi;;
    esac
    command supervisorctl -c "$SM_MAIN_CONF" "$@"
}

_check_daemon_identity() {
    local pid comm detected
    pid=$(_svctl pid 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/comm" ]] || return 1
    IFS= read -r comm < "/proc/$pid/comm" || return 1
    if [[ "$comm" != supervisord ]]; then
        tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Eq '(^|/)supervisord
    [[ -z "$_SM_DAEMON_PID" || "$pid" == "$_SM_DAEMON_PID" ]] || return 1
    detected=$(_daemon_config "$pid") || detected=""
    if [[ -n "$detected" ]]; then
        [[ "$detected" == /* && "$detected" -ef "$SM_MAIN_CONF" ]] || return 1
    else
        [[ -n "$_SM_DAEMON_PID" ]] || return 1
    fi
    return 0
}

ui_menu() {
    local bare=0
    local zero_label="返回"
    # 选项前置开关：--bare 只画分隔线（首页看板模式）；--zero 自定义 0 号项文案
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --bare) bare=1; shift ;;
            --zero) zero_label="${2:-返回}"; shift 2 ;;
            *) break ;;
        esac
    done
    local title="${1:-}"; shift || true
    local options=("$@")
    while true; do
        if (( bare == 0 )); then
            ui_title "$title"
        else
            # bare 模式只画一条分隔线，把菜单与上方看板隔开
            ui_line '-' 
        fi
        local i=1
        for opt in "${options[@]}"; do
            printf "  ${C_CYAN}%2d${C_RESET}) %s\n" "$i" "$opt"
            ((i++))
        done
        echo -e "  ${C_GRAY}0) ${zero_label}${C_RESET}"
        echo
        local choice=""
        read -r -p "$(echo -e "${C_BOLD}请选择${C_RESET} [0-${#options[@]}]: ")" choice || return 1
        # 去除空白（用户可能多按空格）
        choice="${choice// /}"
        # 直接回车 = 不选择，静默重绘（不报错，避免误触时噪音）
        if [[ -z "$choice" ]]; then
            continue
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            ui_error "请输入数字"
            continue
        fi
        # 强制十进制，避免 "08" 被 (( )) / [[ -eq ]] 当作非法八进制
        if (( ${#choice} > 9 )); then ui_error "数字过大"; continue; fi
        choice=$((10#$choice))
        if (( choice < 0 || choice > ${#options[@]} )); then
            ui_error "超出范围 [0-${#options[@]}]"
            continue
        fi
        _SM_MENU_CHOICE="$choice"
        return 0
    done
}

# ============================================================================
#  系统检测
# ============================================================================

detect_pkgmgr() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown; fi
}

detect_init() {
    if [[ -d /run/systemd/system ]]; then echo systemd
    elif command -v rc-update >/dev/null 2>&1; then echo openrc
    else echo unknown; fi
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

require_root() {
    if ! is_root; then
        ui_error "此操作需要 root 权限，请使用 sudo 或切换到 root"
        ui_pause; return 1
    fi
    return 0
}

has_supervisord() { command -v supervisord >/dev/null 2>&1; }

# 判断 supervisord 是否可连通（socket 是否响应）
# 关键：不能用 supervisorctl status —— 任一进程非 RUNNING（FATAL/STOPPED/EXITED/STARTING）
# 时它返回退出码 3，会把"有异常进程"误判成"supervisord 未运行"。
# supervisorctl pid 才是可靠的存活探测：socket 通就返回 supervisord 的 PID 且退出 0。
supervisor_alive() {
    has_supervisord || return 1
    _svctl pid >/dev/null 2>&1
}

# 检测失败原因：区分"未启动"与"无权限访问 socket"
_supervisor_diag() {
    local err
    err=$(_svctl pid 2>&1 >/dev/null)
    if [[ "$err" == *"no such file"* || "$err" == *"refused"* || "$err" == *"不"* ]]; then
        echo "not_running"
    elif [[ "$err" == *"permission"* || "$err" == *"Permission"* || "$err" == *"EACCES"* || "$err" == *"denied"* ]]; then
        echo "no_permission"
    else
        echo "unknown"
    fi
}

# 统一的"supervisord 不可用"提示，按真实原因给出可操作建议
_report_not_alive() {
    local diag; diag=$(_supervisor_diag)
    case "$diag" in
        no_permission)
            ui_error "无权访问 supervisord socket（supervisord 可能正在运行）"
            ui_info "请用 sudo 运行本工具；不要随意放宽 socket 权限"
            ;;
        not_running)
            ui_error "supervisord 未运行"
            ui_info "请执行菜单 [2] 启动并配置开机自启"
            ;;
        *)
            ui_error "无法连接 supervisord"
            ui_info "排查: systemctl status supervisor / journalctl -u supervisor"
            ui_info "确认主配置 [supervisorctl] serverurl 与实际 socket 路径一致"
            ;;
    esac
}

# ============================================================================
#  模块: 安装
# ============================================================================

action_install() (
    require_root || return 1
    ui_title "安装 Supervisor"
    _lock_mutation || return 1
    (( ! _SM_CONF_AMBIGUOUS )) || { ui_error "请先明确配置路径"; return 1; }

    if has_supervisord; then
        ui_warn "已检测到 supervisord: $(supervisord --version 2>/dev/null | head -1)"
        if ! ui_confirm "是否重新安装/覆盖?" "n"; then return 0; fi
    fi

    local pkgmgr; pkgmgr=$(detect_pkgmgr)
    case "$pkgmgr" in
        apt)
            ui_info "使用 apt-get 安装..."
            apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y supervisor || return 1
            ;;
        yum)
            ui_info "使用 yum 安装（先装 EPEL）..."
            yum install -y supervisor || { yum install -y epel-release && yum install -y supervisor; } || return 1
            ;;
        dnf)
            ui_info "使用 dnf 安装（先装 EPEL）..."
            dnf install -y supervisor || { dnf install -y epel-release && dnf install -y supervisor; } || return 1
            ;;
        apk)
            ui_info "使用 apk 安装..."
            apk add --no-cache supervisor || return 1
            ;;
        pacman)
            ui_info "使用 pacman 安装..."
            pacman -S --noconfirm supervisor || return 1
            ;;
        unknown)
            ui_error "无法识别包管理器，请手动安装 supervisor 后重试"
            ui_info "可选: pip install supervisor （但需自建 systemd unit）"
            ui_pause; return 1
            ;;
    esac

    if ! has_supervisord; then
        ui_error "安装命令执行完毕但 supervisord 不可用，请检查输出"
        ui_pause; return 1
    fi
    ui_success "supervisor 已安装: $(supervisord --version 2>/dev/null | head -1)"

    _discover_main_conf || { ui_error "无法唯一识别安装后的主配置"; return 1; }
    mkdir -p "$SM_CONF_DIR" "$SM_LOG_DIR" "$SM_RUN_DIR" "$(dirname "$SM_MAIN_CONF")" || return 1
    local created=0

    if [[ ! -f "$SM_MAIN_CONF" ]]; then
        created=1
        ui_info "生成主配置: $SM_MAIN_CONF"
        # Generate a minimal config only for a fresh installation.
        # 兜底：echo_supervisord_conf 不存在（部分安装包不带）时手写最小可用配置
        if [[ ! -s "$SM_MAIN_CONF" ]]; then
            ui_warn "echo_supervisord_conf 不可用或输出为空，生成最小可用配置"
            (umask 077; cat > "$SM_MAIN_CONF") <<EOF
[unix_http_server]
file=$SM_RUN_DIR/supervisor.sock
chmod=0700

[supervisord]
logfile=$SM_LOG_DIR/supervisord.log
pidfile=$SM_RUN_DIR/supervisord.pid
childlogdir=$SM_LOG_DIR

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$SM_RUN_DIR/supervisor.sock

[include]
files = $SM_CONF_DIR/*.conf
EOF
        fi
    fi

    if (( created )); then
        _native_conf validate "$SM_MAIN_CONF" || { ui_error "新主配置校验失败"; return 1; }
    else
        ui_info "保留已有主配置及 include，不自动改写"
    fi

    ui_info "目录结构:"
    echo "  主配置:        $SM_MAIN_CONF"
    echo "  子进程配置目录: $SM_CONF_DIR"
    echo "  日志目录:      $SM_LOG_DIR"
    echo "  PID/Run 目录:  $SM_RUN_DIR"

    ui_pause
)

# ============================================================================
#  模块: 开机自启
# ============================================================================

action_boot() (
    require_root || return 1
    ui_title "配置开机自启"
    _lock_mutation || return 1
    _conf_ready || return 1

    if ! has_supervisord; then
        ui_error "尚未安装 supervisor，请先执行菜单 [1]"
        ui_pause; return 1
    fi

    local init; init=$(detect_init)
    if supervisor_alive; then _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }; fi
    case "$init" in
        systemd)
            # 用 systemctl cat 探测真实 unit 名，覆盖 /lib、/usr/lib、/etc 各发行版差异
            local svc_name=""
            local cand
            for cand in supervisor supervisord; do
                if systemctl cat "$cand" >/dev/null 2>&1; then
                    if [[ -n "$svc_name" ]] && [[ $(systemctl show "$svc_name" -p Id --value) != $(systemctl show "$cand" -p Id --value) ]]; then ui_error "多个 Supervisor unit，请手动处理"; return 1; fi
                    svc_name="$cand"
                fi
            done

            if [[ -z "$svc_name" ]]; then
                local sup_bin ctl_bin
                sup_bin=$(command -v supervisord)
                ctl_bin=$(command -v supervisorctl)
                if [[ -z "$sup_bin" || -z "$ctl_bin" ]]; then
                    ui_error "无法定位 supervisord/supervisorctl 可执行文件路径，无法生成 unit"
                    ui_pause; return 1
                fi
                _native_conf validate "$SM_MAIN_CONF" || return 1
                [[ "$SM_MAIN_CONF" != *[[:space:]%]* && "$sup_bin" != *[[:space:]%]* && "$ctl_bin" != *[[:space:]%]* ]] || { ui_error "路径含空白或 %，请手动创建 unit"; return 1; }
                ui_confirm "未找到原生 unit，是否创建 supervisor.service?" "n" || return 0
                cat > /etc/systemd/system/supervisor.service <<EOF
[Unit]
Description=Process Monitoring and Control Daemon (Supervisor)
After=network.target

[Service]
Type=simple
ExecStart=$sup_bin -n -c $SM_MAIN_CONF
ExecStop=$ctl_bin -c $SM_MAIN_CONF shutdown
RuntimeDirectory=supervisor
KillMode=control-group
TimeoutStopSec=120
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload || return 1
                svc_name=supervisor
            fi

            local cur_state=disabled cur_active=inactive
            systemctl is-enabled "$svc_name" >/dev/null 2>&1 && cur_state=enabled
            systemctl is-active "$svc_name"  >/dev/null 2>&1 && cur_active=active

            echo "  服务名:       $svc_name"
            echo "  开机自启:     $cur_state"
            echo "  运行状态:     $cur_active"
            echo

            if [[ "$cur_state" == "enabled" && "$cur_active" == "active" ]]; then
                ui_success "已开启开机自启且正在运行"
                if ui_confirm "是否禁用开机自启并停止?" "n"; then
                    systemctl disable --now "$svc_name" \
                        && ui_warn "已禁用并停止" \
                        || ui_error "禁用失败，请检查 systemctl 输出"
                fi
            else
                if ui_confirm "是否启用开机自启并立即启动?"; then
                    if ! systemctl enable --now "$svc_name"; then
                        ui_error "systemctl enable 失败"
                        ui_info "手动排查: systemctl status $svc_name"
                        ui_pause; return 1
                    fi
                    # 服务启动是异步的，轮询等待而不是立刻判定失败
                    local waited=0
                    while (( waited < 50 )); do
                        if systemctl is-active "$svc_name" >/dev/null 2>&1; then
                            break
                        fi
                        # 若已进入 failed 状态则提前退出
                        if systemctl is-failed "$svc_name" >/dev/null 2>&1; then
                            break
                        fi
                        sleep 0.2
                        ((waited++))
                    done

                    if systemctl is-active "$svc_name" >/dev/null 2>&1; then
                        ui_success "已启用并运行"
                        if supervisor_alive; then
                            ui_info "supervisorctl 连通性检查: 正常"
                        else
                            ui_warn "服务已启动但 supervisorctl 无法连通"
                            _report_not_alive
                        fi
                    else
                        ui_error "已 enable 但启动失败"
                        ui_info "排查命令:"
                        echo "    systemctl status $svc_name --no-pager -l"
                        echo "    journalctl -u $svc_name -n 50 --no-pager"
                        echo "    supervisord -n -c $SM_MAIN_CONF   # 前台试跑看报错"
                    fi
                fi
            fi
            ;;
        openrc)
            ui_info "检测到 OpenRC"
            rc-update add supervisor default 2>/dev/null || rc-update add supervisord default 2>/dev/null || {
                ui_error "OpenRC 添加开机自启失败，请手动执行 rc-update add supervisor default"
                ui_pause; return 1
            }
            ui_success "已加入 default 运行级"
            if ui_confirm "是否立即启动 Supervisor?"; then
                if [[ -x /etc/init.d/supervisor ]]; then rc-service supervisor start || return 1
                else rc-service supervisord start || return 1; fi
                supervisor_alive || { _report_not_alive; return 1; }
            fi
            ;;
        *)
            ui_error "无法识别 init 系统，建议手动写 /etc/rc.local 或 cron @reboot"
            ui_pause; return 1
            ;;
    esac
    ui_pause
)

# ============================================================================
#  模块: 状态
# ============================================================================

_list_proc_names() {
    if ! supervisor_alive; then return 0; fi
    # 原样列出第一列：包括 numprocs 实例（name:0/name:1）与组汇总（group:*）
    # supervisorctl 原生支持这些语法，无需也不能过滤
    _svctl status 2>/dev/null | awk '$2 ~ /^(STOPPED|STARTING|RUNNING|BACKOFF|STOPPING|EXITED|FATAL|UNKNOWN)$/ {print $1}'
}

# 读取状态原始输出（首页每轮菜单都会调用）
# 加 5 秒超时上限：socket 卡死时不会把整个菜单拖住；没有 timeout 命令则退化为直接调用
_supervisor_status_raw() {
    if command -v timeout >/dev/null 2>&1; then
        _svctl status 2>/dev/null
    else
        _svctl status 2>/dev/null
    fi
}

# 渲染进程状态表格（首页看板与独立查看共用）
# 返回 0=正常, 1=supervisord 不可用, 2=无受管进程
_render_status_table() {
    if ! has_supervisord; then
        echo -e "  ${C_YELLOW}supervisord 未安装${C_RESET}  → 请选择 [1] 安装"
        return 1
    fi
    if ! supervisor_alive; then
        local diag; diag=$(_supervisor_diag)
        if [[ "$diag" == "no_permission" ]]; then
            echo -e "  ${C_RED}无权访问 supervisord socket${C_RESET}  → 请用 sudo 运行"
        else
            echo -e "  ${C_RED}supervisord 未运行${C_RESET}  → 请选择 [2] 启动并配置开机自启"
        fi
        return 1
    fi

    local raw rc
    raw=$(_supervisor_status_raw); rc=$?
    # 124 = timeout 主动超时；此时 raw 为空，不能误报"暂无受管进程"
    # 注意：supervisorctl status 在有异常进程时本身返回 3，属正常，不能当错误处理
    if (( rc == 124 )); then
        echo -e "  ${C_RED}状态查询超时（supervisord 可能卡死）${C_RESET}  → 检查 $SM_LOG_DIR/supervisord.log"
        return 1
    fi
    if [[ -z "$raw" ]]; then
        echo -e "  ${C_GRAY}（暂无受管进程，选择 [3] 添加）${C_RESET}"
        return 2
    fi

    ( LC_ALL=C; _render_status_body "$raw" )
    return 0
}

# 状态表主体。必须在 LC_ALL=C 的子 shell 里调用——_pad_c 逐字节算显示宽度，
# 依赖 C locale 的字节语义；放在同一个子 shell 里还避免了每格 fork 一次。
#
# supervisorctl status 的列不固定，按状态分支解析：
#   name RUNNING   pid 12345, uptime 0:10:23
#   name RUNNING   pid 12345, uptime 1 day, 2:03:04
#   name FATAL     Exited too quickly (process log may have details)
#   name STOPPED   Sep 12 03:04 PM
#   name STARTING
_render_status_body() {
    local raw="$1"
    local line _n _st rest name state pid uptime color summary
    local total=0 running=0
    local -a lines=()
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        lines+=("$line")
        total=$((total + 1))
        read -r _n _st _ <<< "$line"
        [[ "$_st" == "RUNNING" ]] && running=$((running + 1))
    done <<< "$raw"

    # 颜色：C_* 里存的是字面量 "\033"，给 printf %s 用之前要换成真正的 ESC
    local E=$'\033' R G Y RD GY
    R="${C_RESET//\\033/$E}";  G="${C_GREEN//\\033/$E}"
    Y="${C_YELLOW//\\033/$E}"; RD="${C_RED//\\033/$E}"
    GY="${C_GRAY//\\033/$E}"

    if (( running == total )); then
        summary="共 ${total} 个，${G}全部运行中${R}"
    else
        summary="共 ${total} 个，${G}运行 ${running}${R}，${RD}异常 $((total - running))${R}"
    fi
    # 整个函数已在 LC_ALL=C 子 shell 里，直接调 _pad_c 读 _SM_PAD，不走 $( )（每行省 3 次 fork）
    local p1 p2 p3
    _pad_c "进程状态" 10; printf '  %s%s\n' "$_SM_PAD" "$summary"

    _pad_c "名称" "$_SM_W_NAME";  p1=$_SM_PAD
    _pad_c "状态" "$_SM_W_STATE"; p2=$_SM_PAD
    _pad_c "PID"  "$_SM_W_PID";   p3=$_SM_PAD
    printf '  %s  %s  %s  %s\n' "$p1" "$p2" "$p3" "运行时长"
    _rule "$_SM_W_NAME";  p1=$_SM_PAD
    _rule "$_SM_W_STATE"; p2=$_SM_PAD
    _rule "$_SM_W_PID";   p3=$_SM_PAD
    _rule "$_SM_W_UP"
    printf '  %s  %s  %s  %s\n' "$p1" "$p2" "$p3" "$_SM_PAD"

    for line in "${lines[@]}"; do
        read -r name state rest <<< "$line"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        pid="-"; uptime="-"
        if [[ "$state" == "RUNNING" && "$rest" == "pid "* ]]; then
            # rest = "pid 101, uptime 0:10:23" / "pid 102, uptime 1 day, 2:03:04"
            # rest 的字段：1=pid 2=<PID>, 3=uptime 4...=<时长>
            set -- $rest
            pid="${2:-}"; pid="${pid%,}"
            [[ -z "$pid" ]] && pid="-"
            uptime="${*:4}"
            # "1 day, 2:03:04" / "26 days, 3:04:05" 压成 "1d 2:03:04" / "26d 3:04:05"，
            # 最长 "365d 23:59:59" 也能放进 16 列（原样 "365 days, 23:59:59" 会撑出表格）
            uptime="${uptime// days, /d }"
            uptime="${uptime// day, /d }"
        else
            [[ -n "$rest" ]] && uptime="$rest"
        fi

        case "$state" in
            RUNNING)                              color="$G" ;;
            FATAL|STOPPED)                        color="$RD" ;;
            STARTING|STOPPING|BACKOFF)            color="$Y" ;;
            *)                                    color="$GY" ;;
        esac
        _pad_c "$name"  "$_SM_W_NAME";  p1=$_SM_PAD
        _pad_c "$state" "$_SM_W_STATE"; p2=$_SM_PAD
        _pad_c "$pid"   "$_SM_W_PID";   p3=$_SM_PAD
        printf '  %s  %s%s%s  %s  %s\n' "$p1" "$color" "$p2" "$R" "$p3" "$uptime"
    done
}

# 清屏（仅 tty 下生效；SM_NO_CLEAR=1 可禁用，便于保留滚动历史）
_clear_screen() {
    if [[ "${SM_NO_CLEAR:-0}" != "1" ]] && [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
}

# 独立的"查看状态"屏（首页已自带看板，交互菜单不再用它）
# 保留原因：source 加载本脚本（SM_NO_ENTRY=1）后，其他脚本可直接调用它打印带标题的状态屏
action_status() {
    ui_title "进程状态"
    _render_status_table
    ui_pause
}


# ============================================================================
#  模块: 添加守护进程
# ============================================================================


# Private backup storage and an advisory lock for cooperating SVM sessions.
_private_dir() {
    local dir="$SM_BACKUP_DIR" mode
    [[ "$dir" == /* && ! -L "$dir" ]] || return 1
    (umask 077; mkdir -p -- "$dir") || return 1
    [[ -d "$dir" && ! -L "$dir" && $(stat -c %u -- "$dir") == "$EUID" ]] || return 1
    mode=$(stat -c %a -- "$dir") || return 1
    if [[ "$dir" == /var/backups/supervisor-manager && "$mode" == 755 ]]; then
        chmod 0700 -- "$dir" || return 1
        mode=700
    fi
    [[ "$mode" == 700 ]] || { ui_error "备份目录权限必须为 0700: $dir" >&2; return 1; }
}

_lock_mutation() {
    require_root || return 1
    _private_dir || { ui_error "无法建立安全备份目录，取消操作"; return 1; }
    command -v flock >/dev/null 2>&1 || { ui_error "缺少 flock（util-linux）"; return 1; }
    [[ ! -L "$SM_BACKUP_DIR/.lock" ]] || return 1
    exec 9>>"$SM_BACKUP_DIR/.lock" || return 1
    flock -n 9 || { ui_error "另一 SVM 会话正在修改配置"; return 1; }
}

_safe_target() {
    local file="$1" dir owner mode
    [[ "$file" == /* && ! -L "$file" && ! -d "$file" ]] || return 1
    dir=$(dirname -- "$file")
    [[ -d "$dir" ]] || return 1
    owner=$(stat -Lc %u -- "$dir") || return 1
    mode=$(stat -Lc %a -- "$dir") || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    if [[ -e "$file" ]]; then
        [[ -f "$file" && $(stat -c %u -- "$file") == "$EUID" ]] || return 1
    fi
}

_atomic_publish() {
    local src="$1" dst="$2" tmp mode=0600
    _safe_target "$dst" || { ui_error "拒绝不安全的写入目标: $dst"; return 1; }
    tmp=$(mktemp "$(dirname -- "$dst")/.svm.XXXXXXXX") || return 1
    if [[ -f "$dst" ]]; then mode=$(stat -c %a -- "$dst") || { rm -f -- "$tmp"; return 1; }; fi
    if ! cat -- "$src" > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$dst"; then
        rm -f -- "$tmp"; return 1
    fi
}

_reread_groups() {
    local out line
    out=$(_svctl reread 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "No config updates to processes" ]] && continue
        if [[ "$line" =~ ^([^[:space:]:]+):[[:space:]](available|changed|disappeared)$ ]]; then
            [[ "${BASH_REMATCH[1]}" != all && "${BASH_REMATCH[1]}" != -* ]] || return 1
            printf '%s\n' "${BASH_REMATCH[1]}"
        else
            printf '无法识别 reread 输出: %s\n' "$line" >&2; return 1
        fi
    done <<< "$out"
}

_tx_begin() {
    _conf_ready || return 1
    _lock_mutation || return 1
    _TX_TARGET="$1"; _TX_BACKUP=""; _TX_STAGE=""; _TX_DIRTY=0
    _TX_ONLINE=0; _TX_APPLY=0; _TX_MAIN_RESTART=0; _TX_GROUPS=""; _TX_MODE=0600
    _safe_target "$_TX_TARGET" || { ui_error "不安全的目标: $_TX_TARGET"; return 1; }
    _conf_include_patterns >/dev/null || return 1
    _native_conf validate "$SM_MAIN_CONF" || { ui_error "现有配置无效，请先手动恢复"; return 1; }
    if supervisor_alive; then
        _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }
        local pending
        pending=$(_reread_groups) || return 1
        [[ -z "$pending" ]] || {
            ui_error "已有未应用的配置修改，请先使用菜单 [9] 或手工处理"
            printf '%s\n' "$pending"; return 1;
        }
        _TX_ONLINE=1
    elif [[ -n "$_SM_DAEMON_PID" ]] || pgrep -x supervisord >/dev/null 2>&1; then
        ui_error "发现运行中的 Supervisor 但无法确认连接，拒绝写入"; return 1
    fi
    if [[ -f "$_TX_TARGET" ]]; then
        _TX_MODE=$(stat -c %a -- "$_TX_TARGET") || return 1
        _TX_BACKUP=$(_backup_file "$_TX_TARGET") || { ui_error "备份失败，取消修改"; return 1; }
        ui_info "已备份: $_TX_BACKUP"
    fi
    _TX_STAGE=$(mktemp "$SM_BACKUP_DIR/.stage.XXXXXXXX") || return 1
    trap '_tx_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -n "$_TX_BACKUP" ]]; then cat -- "$_TX_BACKUP" > "$_TX_STAGE" || return 1; fi
}

_tx_cleanup() {
    local rc=$?
    trap - EXIT
    trap '' INT TERM
    if (( _TX_DIRTY )); then
        ui_warn "操作未提交，恢复磁盘配置"
        local restored=1
        if [[ -n "$_TX_BACKUP" ]]; then
            if _atomic_publish "$_TX_BACKUP" "$_TX_TARGET"; then chmod "$_TX_MODE" -- "$_TX_TARGET" || restored=0; else restored=0; fi
        else
            rm -f -- "$_TX_TARGET" || restored=0
        fi
        if (( ! restored )); then
            ui_error "自动恢复失败！目标: $_TX_TARGET；备份: $_TX_BACKUP"
        elif (( _TX_ONLINE )); then
            if (( _TX_MAIN_RESTART )); then
                _restart_supervisor || ui_error "磁盘已恢复，但服务重启失败，请人工检查"
            else
                local groups g
                groups=$(_reread_groups) || { ui_error "磁盘已恢复，但 reread 失败"; groups=""; }
                if (( _TX_APPLY )) && [[ -n "$groups" ]]; then
                    while IFS= read -r g; do
                        [[ -n "$g" ]] || continue
                        if grep -Fxq -- "$g" <<< "$_TX_GROUPS"; then
                            _svctl update "$g" || ui_error "组 $g 运行态恢复失败"
                        else
                            ui_warn "未自动应用无关组 $g"
                        fi
                    done <<< "$groups"
                    ui_warn "运行态恢复为尽力而为；请复核原手动启停状态"
                fi
            fi
        fi
        (( rc == 0 )) && rc=1
    fi
    [[ -z "$_TX_STAGE" ]] || rm -f -- "$_TX_STAGE"
    exit "$rc"
}

_tx_publish() {
    if [[ -n "$_TX_BACKUP" ]]; then
        cmp -s -- "$_TX_TARGET" "$_TX_BACKUP" || { ui_error "配置已被外部修改"; return 1; }
    else
        [[ ! -e "$_TX_TARGET" && ! -L "$_TX_TARGET" ]] || { ui_error "目标已存在"; return 1; }
    fi
    _TX_DIRTY=1
    _atomic_publish "$_TX_STAGE" "$_TX_TARGET"
}

_tx_apply() {
    _native_conf validate "$SM_MAIN_CONF" || return 1
    if (( _TX_ONLINE )); then
        _TX_GROUPS=$(_reread_groups) || return 1
        if [[ -n "$_TX_GROUPS" ]]; then
            local -a groups=()
            local g remaining
            while IFS= read -r g; do [[ -n "$g" ]] && groups+=("$g"); done <<< "$_TX_GROUPS"
            ui_info "仅应用变更组: ${groups[*]}"
            _TX_APPLY=1
            _svctl update "${groups[@]}" || return 1
            remaining=$(_reread_groups) || return 1
            [[ -z "$remaining" ]] || { ui_error "仍有未应用的配置变更"; return 1; }
        fi
    else
        ui_info "配置已通过离线解析；下次启动时生效"
    fi
    _TX_DIRTY=0
}

_restart_supervisor() {
    local init svc="" cand waited=0
    init=$(detect_init)
    case "$init" in
        systemd)
            for cand in supervisor supervisord; do
                if systemctl cat "$cand" >/dev/null 2>&1; then
                    if [[ -n "$svc" ]] && [[ $(systemctl show "$svc" -p Id --value) != $(systemctl show "$cand" -p Id --value) ]]; then
                        ui_error "存在多个 Supervisor unit，请手动重启"; return 1
                    fi
                    svc="$cand"
                fi
            done
            [[ -n "$svc" ]] || return 1
            systemctl restart "$svc" || return 1;;
        openrc)
            for cand in supervisor supervisord; do
                [[ -x "/etc/init.d/$cand" ]] || continue
                [[ -z "$svc" ]] || return 1
                svc="$cand"
            done
            [[ -n "$svc" ]] || return 1
            rc-service "$svc" restart || return 1;;
        *) ui_error "未知 init，请手动重启"; return 1;;
    esac
    while (( waited < 20 )); do
        supervisor_alive && return 0
        sleep 0.5; ((waited++))
    done
    return 1
}

action_add() (
    require_root || return 1
    ui_title "添加守护进程"

    if ! has_supervisord; then
        ui_error "尚未安装 supervisor"
        ui_pause; return 1
    fi

    echo -e "${C_GRAY}按提示逐步填写，留空使用默认值。Ctrl+C 取消。${C_RESET}"
    echo

    local name command user directory autostart autorestart stdout_log stderr_log priority env_str

    # 所有后续输入统一做 EOF 保护：任一 read 失败立即中止，避免写出空字段配置
    name=$(_ask_or_abort "进程名称(英文，作为program段名)") || { ui_pause; return 0; }

    if [[ -z "$name" ]]; then
        ui_error "名称不能为空"
        ui_pause; return 1
    fi
    # 进程名会成为 [program:x] 段名，必须符合 supervisor 命名规则
    if ! [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || [[ "$name" == all ]]; then
        ui_error "名称只能包含字母、数字、下划线、点、连字符（不含空格/斜杠/冒号）"
        ui_info "示例: myapp / web_api / worker-01"
        ui_pause; return 1
    fi
    # 写入位置必须以 include 为准：目录和后缀都要对，否则 supervisord 永远不会加载
    _conf_ready || return 1
    _preferred_conf_target "$name" || return 1
    local target="$_SM_TARGET_FILE"
    local conf_dir="${target%/*}"
    local name_rc=0
    _program_exists "$name" || name_rc=$?
    (( name_rc == 1 )) || { ui_error "名称重复或解析失败"; return 1; }
    if [[ -e "$target" || -L "$target" ]]; then
        ui_error "已存在同名进程 [program:$name]，请改用菜单 [8] 编辑"
        ui_pause; return 1
    fi

    command=$(_ask_or_abort "启动命令" "/usr/local/bin/$name") || { ui_pause; return 0; }
    user=$(_ask_or_abort "运行用户" "root") || { ui_pause; return 0; }
    directory=$(_ask_or_abort "工作目录" "/") || { ui_pause; return 0; }
    autostart=$(_ask_or_abort "随supervisor启动(y/n)" "y") || { ui_pause; return 0; }
    autorestart=$(_ask_or_abort "自动重启(true/unexpected/false)" "true") || { ui_pause; return 0; }
    priority=$(_ask_or_abort "启动优先级(数字越小越早)" "999") || { ui_pause; return 0; }
    stdout_log=$(_ask_or_abort "stdout日志路径" "$SM_LOG_DIR/$name.log") || { ui_pause; return 0; }
    stderr_log=$(_ask_or_abort "stderr日志路径" "$SM_LOG_DIR/$name-error.log") || { ui_pause; return 0; }
    env_str=$(_ask_or_abort "环境变量(KEY1=val1,KEY2=val2 可空)" "") || { ui_pause; return 0; }

    # command 是必填项，空配置会让进程直接 FATAL
    if [[ -z "$command" ]]; then
        ui_error "启动命令不能为空"
        ui_pause; return 1
    fi
    # 优先级必须是非负整数
    if ! [[ "$priority" =~ ^[0-9]+$ ]]; then
        ui_warn "优先级 '$priority' 非数字，回退为默认 999"
        priority=999
    fi
    # 日志路径建议绝对路径（supervisord 的工作目录与当前 shell 不同）
    if [[ "$stdout_log" != /* || "$stderr_log" != /* ]]; then
        ui_warn "日志路径建议使用绝对路径，相对路径会相对 supervisord 的启动目录解析"
        if ! ui_confirm "仍要继续?" "n"; then
            ui_warn "已取消"; ui_pause; return 0
        fi
    fi

    autostart=$(_to_bool "$autostart")
    case "$autorestart" in true|y|yes) autorestart=true;; unexpected) ;; false|n|no) autorestart=false;; *) ui_error "无效重启策略"; return 1;; esac
    id "$user" >/dev/null 2>&1 || { ui_error "运行用户不存在"; return 1; }
    [[ -d "$directory" && "$directory" == /* ]] || { ui_error "工作目录必须为存在的绝对路径"; return 1; }

    ui_title "预览配置"
    echo "[program:$name]"
    echo "command=$command"
    echo "directory=$directory"
    echo "user=$user"
    echo "autostart=$autostart"
    echo "autorestart=$autorestart"
    echo "priority=$priority"
    echo "stdout_logfile=$stdout_log"
    echo "stderr_logfile=$stderr_log"
    [[ -n "$env_str" ]] && echo "environment=（已隐藏）"
    echo

    if ! ui_confirm "确认写入并加载?"; then
        ui_warn "已取消"; ui_pause; return 0
    fi

    _tx_begin "$target" || return 1
    [[ -z "$_TX_BACKUP" ]] || { ui_error "目标已存在"; return 1; }
    name_rc=0; _program_exists "$name" || name_rc=$?
    (( name_rc == 1 )) || return 1
    mkdir -p -- "$(dirname -- "$stdout_log")" "$(dirname -- "$stderr_log")" || return 1
    {
        printf '%s\n' "[program:$name]" "command=$command" "directory=$directory" "user=$user"
        printf '%s\n' "autostart=$autostart" "autorestart=$autorestart" "priority=$priority"
        printf '%s\n' "stdout_logfile=$stdout_log" "stderr_logfile=$stderr_log"
        printf '%s\n' 'stdout_logfile_maxbytes=8MB' 'stdout_logfile_backups=3'
        printf '%s\n' 'stderr_logfile_maxbytes=8MB' 'stderr_logfile_backups=3'
        printf '%s\n' 'stopasgroup=true' 'killasgroup=true'
        if [[ -n "$env_str" ]]; then printf '%s\n' "environment=$env_str"; fi
    } > "$_TX_STAGE" || return 1
    _tx_publish || return 1
    local files
    files=$(_conf_source_files) || return 1
    grep -Fxq -- "$target" <<< "$files" || { ui_error "新文件未被 include 匹配"; return 1; }
    _tx_apply || return 1
    ui_success "配置添加完成: $target"
    if (( _TX_ONLINE )); then
        if [[ "$autostart" == false ]] && ui_confirm "是否立即启动?" "n"; then
            _svctl start "$name" || { ui_error "配置已加载，但启动失败"; return 1; }
        fi
        _svctl status "$name" || ui_warn "配置已加载，进程未处于 RUNNING，请查看日志"
    fi
    ui_pause

)

# ============================================================================
#  模块: 启停重启
# ============================================================================

# 选择操作目标，结果写入全局 _SM_TARGET
# 注意：不能用 $(...) 取值 —— ui_menu 会把选项列表打印到 stdout，
# 被命令替换捕获后 target 会变成"整段菜单文本 + 进程名"，supervisorctl 必然报 no such process。
_promote_target() {
    local op="$1"
    _SM_TARGET=""
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(_list_proc_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        ui_error "当前没有受管进程"
        ui_pause; return 1
    fi
    local options=()
    for n in "${names[@]}"; do options+=("$n"); done
    options+=("全部 (all)")
    if ! ui_menu "选择要${op}的进程" "${options[@]}"; then return 1; fi
    local choice="$_SM_MENU_CHOICE"
    if [[ "$choice" -eq 0 ]]; then return 1; fi
    if [[ "$choice" -eq $(( ${#names[@]} + 1 )) ]]; then
        _SM_TARGET="all"
    else
        _SM_TARGET="${names[$((choice-1))]}"
    fi
    return 0
}

action_start()   { _action_ctl "启动" "start"; }
action_stop()    { _action_ctl "停止"  "stop"; }
action_restart() { _action_ctl "重启"  "restart"; }

_action_ctl() {
    local op="$1"; local cmd="$2"
    ui_title "${op}进程"
    if ! supervisor_alive; then
        _report_not_alive; ui_pause; return 1
    fi
    _promote_target "$op" || { ui_pause; return 0; }
    local target="$_SM_TARGET"
    _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }
    if [[ "$target" == all && "$cmd" != start ]]; then ui_confirm "确认${op}全部进程?" "n" || return 0; fi
    [[ -n "$target" ]] || { ui_warn "未选择目标"; ui_pause; return 0; }
    ui_info "执行 supervisorctl $cmd $target ..."
    if _svctl "$cmd" "$target"; then
        ui_success "${op}完成"
    else
        ui_error "${op}失败"
    fi
    ui_pause
}

# ============================================================================
#  模块: 日志
# ============================================================================

action_log() {
    ui_title "查看日志"
    if ! supervisor_alive; then
        _report_not_alive; ui_pause; return 1
    fi
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(_list_proc_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        ui_error "没有受管进程"; ui_pause; return 1
    fi
    if ! ui_menu "选择进程" "${names[@]}"; then ui_pause; return 0; fi
    local choice="$_SM_MENU_CHOICE"
    [[ "$choice" -eq 0 ]] && { ui_pause; return 0; }
    local name="${names[$((choice-1))]}"

    local actions=(
        "查看 stdout 末尾 (tail)"
        "查看 stderr 末尾 (tail)"
        "实时跟随 stdout (tail -f)"
        "实时跟随 stderr (tail -f)"
        "只读查看 stdout_logfile"
        "只读查看 stderr_logfile"
    )
    if ! ui_menu "选择日志动作 [$name]" "${actions[@]}"; then ui_pause; return 0; fi
    local act="$_SM_MENU_CHOICE"
    [[ "$act" -eq 0 ]] && { ui_pause; return 0; }

    case "$act" in
        1) _svctl tail "$name" stdout ;;
        2) _svctl tail "$name" stderr ;;
        3) echo -e "${C_GRAY}Ctrl+C 退出${C_RESET}"; _svctl tail -f "$name" stdout ;;
        4) echo -e "${C_GRAY}Ctrl+C 退出${C_RESET}"; _svctl tail -f "$name" stderr ;;
        5|6)
            local key
            if [[ "$act" -eq 5 ]]; then key=stdout_logfile; else key=stderr_logfile; fi
            local file
            file=$(_lookup_key "$name" "$key")

            if [[ -z "$file" || "$file" != /* || ! -f "$file" ]]; then
                ui_warn "实际日志不存在或不可用，建议使用 Supervisor tail"
            else
                tail -n 100 -- "$file"
            fi
            ;;
    esac
    ui_pause
}

# ============================================================================
#  模块: 编辑/删除/重载/主配置
# ============================================================================

# 文件指纹：判断"编辑到底有没有改内容"，避免没改也提示重载
_file_sig() {
    if [[ -f "$1" ]]; then
        cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'
    else
        echo "missing"
    fi
}

# 编辑前备份，成功则输出备份路径；失败返回 1（调用方只 warn，不阻塞编辑）
_backup_file() {
    local file="$1" dest
    [[ -f "$file" && ! -L "$file" ]] || return 1
    _private_dir || return 1
    dest=$(mktemp "$SM_BACKUP_DIR/${file##*/}.XXXXXXXX") || return 1
    if ! cat -- "$file" > "$dest" || ! chmod 0600 "$dest"; then rm -f -- "$dest"; return 1; fi
    printf '%s\n' "$dest"
}

# 执行 reread + update，返回 0=成功 1=失败
# 关键：supervisorctl reread 遇到配置语法错误会打印 ERROR 并以非 0 退出，
# 若忽略返回值，工具会继续打印"重载完成"，用户以为改动生效了——实际 supervisord
# 仍在用内存里的旧配置。这是"编辑配置后没反应"最常见的原因。
_do_reload() {
    local out rc
    out=$(_svctl reread 2>&1); rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out"
    if (( rc != 0 )) || [[ "$out" == *ERROR* ]]; then
        ui_error "reread 失败：配置有语法错误，本次改动未生效"
        ui_info "常见原因：段名应为 [program:name]、缺 command、引号/方括号不配对"
        ui_info "supervisord 仍在运行改动前的配置，进程未受影响"
        return 1
    fi

    out=$(_svctl update 2>&1); rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out"
    if (( rc != 0 )) || [[ "$out" == *ERROR* ]]; then
        ui_error "update 失败：新配置未完全应用"
        return 1
    fi
    return 0
}

# 列出 supervisord 实际会加载的进程配置文件（完整路径，已去重）
# 依据 include，而不是硬编码 SM_CONF_DIR —— 详见"配置文件定位"一节
_list_conf_files() {
    local f list
    list=$(_conf_source_files) || return 1
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" && ! "$f" -ef "$SM_MAIN_CONF" ]] || continue
        printf '%s\n' "$f"
    done <<< "$list"
}

# 列表为空时的诊断：把"为什么空"讲清楚，而不是只说目录为空
_conf_diag_empty() {
    ui_info "主配置:   ${SM_MAIN_CONF}（$( [[ -f "$SM_MAIN_CONF" ]] && echo 存在 || echo '不存在')）"
    local pats
    pats=$(_conf_include_patterns "$SM_MAIN_CONF" 2>/dev/null | tr '\n' ' ')
    if [[ -n "${pats// /}" ]]; then
        ui_info "[include] files: $pats"
        ui_info "展开后没有匹配到文件，检查该路径/后缀是否写对（ls 一下）"
    else
        ui_warn "主配置里没有可解析的 [include] files"
        ui_info "进程可能直接写在主配置中——这种情况请用菜单 [11] 编辑主配置"
    fi
    ui_info "也可用 SM_MAIN_CONF=... 或 SM_CONF_DIR=... 指定实际路径后重试"
}

action_edit() (
    require_root || return 1
    ui_title "编辑进程配置"
    local list f file
    list=$(_list_conf_files) || return 1
    local -a files=()
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done <<< "$list"
    if (( ${#files[@]} == 0 )); then _conf_diag_empty; ui_pause; return 1; fi
    ui_menu "选择配置文件（可能包含多个进程）" "${files[@]}" || return 0
    [[ "$_SM_MENU_CHOICE" != 0 ]] || return 0
    file="${files[$((_SM_MENU_CHOICE-1))]}"
    _tx_begin "$file" || return 1
    _open_editor "$_TX_STAGE" || { ui_error "编辑器退出异常，未修改正式配置"; return 1; }
    if cmp -s -- "$_TX_STAGE" "$_TX_BACKUP"; then ui_info "配置未改变"; return 0; fi
    ui_confirm "确认保存并应用配置?" "n" || return 0
    _tx_publish || return 1
    _tx_apply || return 1
    ui_success "配置修改完成"
    ui_pause
)

# 从一个配置文件里提取受管实体名（[program:x] / [group:x]）
# 一个 .conf 里可能定义多个 program，直接拿文件名去 stop 会 no such process
_conf_entity_names() {
    local file="$1"
    awk '
        /^[[:space:]]*\[(program|group):/ {
            line = $0
            sub(/^[[:space:]]*\[/, "", line)
            sub(/\].*$/, "", line)
            sub(/^(program|group):[[:space:]]*/, "", line)
            if (length(line) > 0) print line
        }
    ' "$file" 2>/dev/null
}

action_delete() (
    require_root || return 1
    ui_title "删除整个配置文件"
    local list f file sections
    list=$(_list_conf_files) || return 1
    local -a files=()
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done <<< "$list"
    if (( ${#files[@]} == 0 )); then _conf_diag_empty; return 1; fi
    ui_menu "选择整个配置文件" "${files[@]}" || return 0
    [[ "$_SM_MENU_CHOICE" != 0 ]] || return 0
    file="${files[$((_SM_MENU_CHOICE-1))]}"
    _tx_begin "$file" || return 1
    [[ -n "$_TX_BACKUP" ]] || return 1
    sections=$(_native_conf entities "$_TX_BACKUP") || return 1
    ui_warn "即将删除 $file 的全部段（不是单个进程）:"
    printf '%s\n' "$sections"
    ui_confirm "确认删除整个文件并停止受影响进程组?" "n" || return 0
    cmp -s -- "$file" "$_TX_BACKUP" || { ui_error "配置已被外部修改"; return 1; }
    _TX_DIRTY=1
    rm -- "$file" || return 1
    _tx_apply || return 1
    ui_success "已删除配置文件: $file"
    ui_pause
)

action_reload() (
    _lock_mutation || return 1
    ui_title "全局重载 Supervisor 配置"
    _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }
    _native_conf validate "$SM_MAIN_CONF" || return 1
    ui_warn "全局 update 可能重启所有存在未应用修改的进程组"
    ui_confirm "确认全局应用?" "n" || return 0
    if _do_reload; then
        ui_success "重载完成"; _render_status_table
    else
        ui_error "重载失败或部分应用，请检查实际运行状态"
        ui_pause; return 1
    fi
    ui_pause
)

action_edit_main() (
    require_root || return 1
    ui_title "编辑主 supervisord.conf"
    _conf_ready || return 1
    _tx_begin "$SM_MAIN_CONF" || return 1
    _open_editor "$_TX_STAGE" || return 1
    if cmp -s -- "$_TX_STAGE" "$_TX_BACKUP"; then ui_info "配置未改变"; return 0; fi
    ui_warn "主配置变更可能影响全部进程；重启会中断业务"
    ui_confirm "确认保存主配置?" "n" || return 0
    _tx_publish || return 1
    _native_conf validate "$SM_MAIN_CONF" || return 1
    if (( _TX_ONLINE )) && ui_confirm "立即重启 Supervisor 并检查连接?" "n"; then
        _TX_MAIN_RESTART=1
        _restart_supervisor || return 1
        _TX_DIRTY=0
        ui_success "已保存并重启"
    else
        _TX_DIRTY=0
        ui_warn "主配置已保存且通过解析；全局设置需下次重启才能生效"
    fi
    ui_pause
)

# ============================================================================
#  主菜单
# ============================================================================

main_menu() {
    while true; do
        _discover_main_conf || true
        # 首页 = 状态看板 + 菜单（一屏看完，不用再单独进"查看状态"）
        # _SM_SKIP_CLEAR=1 用于跳过本次清屏（看日志回来时保留刚读到的内容）
        if [[ "${_SM_SKIP_CLEAR:-0}" == "1" ]]; then
            _SM_SKIP_CLEAR=0
            echo
        else
            _clear_screen
        fi
        # locale 自适应的一次性提示：放在清屏之后，否则首屏会被刷掉
        if [[ -n "$_SM_LOCALE_NOTE" ]]; then
            echo -e "$_SM_LOCALE_NOTE"
            _SM_LOCALE_NOTE=""
        fi
        ui_title "Supervisor Manager v$SM_VERSION"
        _render_status_table

        if ! ui_menu --bare --zero "退出" "" \
            "安装 Supervisor" \
            "配置开机自启" \
            "添加守护进程" \
            "启动进程" \
            "停止进程" \
            "重启进程" \
            "查看/跟随日志" \
            "编辑进程配置" \
            "重载 supervisor 配置 (reread+update)" \
            "删除守护进程" \
            "编辑主 supervisord.conf"; then
            # EOF（Ctrl-D / 管道结束）
            echo "再见"; exit 0
        fi
        local choice="$_SM_MENU_CHOICE"
        case "$choice" in
            1)  action_install ;;
            2)  action_boot ;;
            3)  action_add ;;
            4)  action_start ;;
            5)  action_stop ;;
            6)  action_restart ;;
            7)  action_log; _SM_SKIP_CLEAR=1 ;;
            8)  action_edit ;;
            9)  action_reload ;;
            10) action_delete ;;
            11) action_edit_main ;;
            0)  echo "再见"; exit 0 ;;
        esac
    done
}

# ============================================================================
#  Self-install: 把脚本自身安装到 /usr/local/bin/svm（或自定义名字）
# ============================================================================

# 检测 PATH 中的某个命令是否是本工具自身
# 注意：特征串不带版本号——否则新版脚本检测旧版安装会误判为"非本工具"
_is_self_cmd() {
    local cmd_path="$1"
    [[ -f "$cmd_path" && ! -L "$cmd_path" ]] || return 1
    grep -q '^#  sm.sh - Supervisor Manager (interactive shell, menu-driven)' "$cmd_path" &&
        grep -q '^SM_VERSION="[0-9]' "$cmd_path"
}

# 提取已安装版本的版本号（读 SM_VERSION="x.y.z" 行）
_get_self_version() {
    local cmd_path="$1"
    [[ -f "$cmd_path" ]] || return 1
    sed -n 's/^SM_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$cmd_path" 2>/dev/null | head -1
}

# 寻找一个可用的命令名（svm 优先，冲突则尝试 svmgr/supmgr）
_pick_install_name() {
    local prefer="$1"
    local candidates=("$prefer")
    [[ "$prefer" != "svm" ]] && candidates+=("svm")
    candidates+=("svmgr" "supmgr" "supvmgr")

    local existing
    for name in "${candidates[@]}"; do
        existing=$(command -v "$name" 2>/dev/null || true)
        if [[ -z "$existing" ]]; then
            echo "$name"; return 0
        fi
        # 已存在，但是否是本工具自身？
        if _is_self_cmd "$existing"; then
            echo "$name"; return 0
        fi
    done
    # 全都冲突
    echo ""
    return 1
}

self_install() {
    local install_name="svm"
    local install_path="/usr/local/bin"
    local force=0

    # 解析剩余参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    ui_error "--as 需要一个命令名参数"
                    return 1
                fi
                install_name="$2"; shift 2 ;;
            --path)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    ui_error "--path 需要一个目录参数"
                    return 1
                fi
                install_path="$2"; shift 2 ;;
            --force|-f)
                force=1; shift ;;
            --help|-h)
                cat <<EOF
用法: sm.sh --install [--as NAME] [--path PATH] [--force]

  --as NAME      指定安装后的命令名（默认 svm，冲突则自动尝试 svmgr/supmgr）
  --path PATH    安装目录（默认 /usr/local/bin）
  --force        跳过冲突检测，强制覆盖

示例:
  sm.sh --install                    # 安装为 svm（冲突则降级）
  sm.sh --install --as svmgr         # 强制安装为 svmgr
  sm.sh --install --path /opt/bin    # 装到 /opt/bin/svm
EOF
                return 0
                ;;
            *) ui_error "未知参数: $1"; return 1 ;;
        esac
    done

    require_root || return 1

    ui_title "Self-install"

    # 安装目录检查
    if [[ ! -d "$install_path" ]]; then
        ui_error "安装目录不存在: $install_path"
        ui_info "请先 mkdir -p $install_path 或换一个目录"
        return 1
    fi

    [[ "$install_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { ui_error "无效命令名"; return 1; }
    [[ "$install_path" == /* ]] || { ui_error "安装目录必须为绝对路径"; return 1; }
    local final_name="$install_name" target src existing candidate backup tmp version
    local -a candidates=("$install_name")
    [[ "$install_name" != svm ]] || candidates+=(svmgr supmgr supvmgr)
    if (( ! force )); then
        final_name=""
        for candidate in "${candidates[@]}"; do
            if _is_self_cmd "$install_path/$candidate"; then final_name="$candidate"; break; fi
        done
        if [[ -z "$final_name" ]]; then
            for candidate in "${candidates[@]}"; do
                existing=$(command -v "$candidate" 2>/dev/null || true)
                [[ -z "$existing" && ! -e "$install_path/$candidate" && ! -L "$install_path/$candidate" ]] || continue
                final_name="$candidate"; break
            done
        fi
        [[ -n "$final_name" ]] || { ui_error "目标命令冲突"; return 1; }
    fi
    target="$install_path/$final_name"
    _safe_target "$target" || { ui_error "不安全的安装目标"; return 1; }
    src=$(readlink -f "${BASH_SOURCE[0]}") || return 1
    [[ -f "$src" ]] || return 1
    bash -n "$src" || return 1
    if [[ -f "$target" ]] && cmp -s -- "$src" "$target"; then
        ui_success "已安装相同内容: $target"; return 0
    fi
    ui_info "安装目标: $target（仅更新管理工具）"
    ui_confirm "确认安装/升级?" "n" || return 0
    if [[ -e "$target" ]]; then
        version=$(_get_self_version "$target" || true)
        backup=$(mktemp "$target.v${version:-old}.XXXXXXXX") || return 1
        if ! cp -p -- "$target" "$backup"; then rm -f -- "$backup"; ui_error "备份失败"; return 1; fi
        ui_info "原文件备份: $backup"
    fi
    tmp=$(mktemp "$install_path/.svm-install.XXXXXXXX") || return 1
    if ! install -m 0755 -- "$src" "$tmp" || ! mv -fT -- "$tmp" "$target"; then
        rm -f -- "$tmp"; ui_error "安装失败"; return 1
    fi
    ui_success "安装完成: $target"

    # PATH 检查
    case ":$PATH:" in
        *":$install_path:"*) ;;
        *) ui_warn "注意: $install_path 不在 PATH 中，请手动加入" ;;
    esac

    # 验证
    if command -v "$final_name" >/dev/null 2>&1; then
        ui_info "验证: $(command -v "$final_name")"
        ui_info "现在可以直接输入 '$final_name' 启动"
    else
        ui_warn "命令未在 PATH 中找到，需重新登录或 source ~/.bashrc"
    fi

    # 升级/安装后的完整性检查：supervisord 与其开机自启状态
    echo
    ui_info "── 环境检查 ──"
    if has_supervisord; then
        ui_info "supervisord 已安装: $(supervisord --version 2>/dev/null | head -1)"
        if supervisor_alive; then
            ui_info "supervisord 运行中"
        else
            ui_warn "supervisord 未运行，运行 '$final_name' 进菜单 [2] 启动"
        fi
        # systemd 开机自启检查（不适用于非 systemd 环境）
        if [[ -d /run/systemd/system ]]; then
            local svc
            for svc in supervisor supervisord; do
                if systemctl cat "$svc" >/dev/null 2>&1; then
                    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
                        ui_info "开机自启 ($svc): 已启用"
                    else
                        ui_warn "开机自启 ($svc): 未启用，运行 '$final_name' 进菜单 [2] 配置"
                    fi
                    break
                fi
            done
        fi
    else
        ui_warn "supervisord 未安装，运行 '$final_name' 进菜单 [1] 安装"
    fi

    # 提示典型用法
    cat <<EOF

${C_GRAY}── 常用入口 ──${C_RESET}
  $final_name              # 进入交互菜单
  $final_name --install    # 安装/升级本命令（带 --as/--path）
  $final_name -c status    # 一次性命令：直接显示状态

EOF
}

# ============================================================================
#  用法 / 帮助
# ============================================================================

self_uninstall() (
    require_root || return 1
    local target="${1:-$(readlink -f "${BASH_SOURCE[0]}")}"
    [[ $# -le 1 && "$target" == /* ]] || { ui_error "用法: svm --uninstall [绝对安装路径]"; return 1; }
    _safe_target "$target" && _is_self_cmd "$target" || { ui_error "拒绝删除非本工具文件"; return 1; }
    ui_confirm "仅卸载 $target（保留 Supervisor、配置、备份、运行进程）?" "n" || return 0
    rm -- "$target" || return 1
    ui_success "管理工具已卸载"
)
usage() {
    cat <<EOF
${C_BOLD}Supervisor Manager v$SM_VERSION${C_RESET}

用法:
  sm.sh                       进入交互式菜单
  sm.sh --install [选项]      安装/升级为系统命令（默认 svm，冲突则降级 svmgr）
  svm --uninstall [绝对路径]  仅卸载管理工具
  sm.sh -c <cmd>              一次性命令
  sm.sh --help                显示本帮助

--install 选项:
  --as NAME                   指定命令名（默认 svm）
  --path PATH                 安装目录（默认 /usr/local/bin）
  --force                     跳过冲突检测

升级说明:
  用新版脚本重新执行 --install 即可升级；旧版本自动备份为带版本号和随机后缀的文件
  覆盖安装只更新本命令，不影响 /etc/supervisor 配置、systemd unit 与运行中的进程

-c 支持的命令:
  status                      supervisorctl status
  install                     调用菜单 [1]
  boot                        调用菜单 [2]

环境变量:
  SM_CONF_DIR                 子进程配置目录（默认 /etc/supervisor/conf.d）
  SM_MAIN_CONF                主配置文件
  SM_LOG_DIR                  日志目录
  SM_BACKUP_DIR               编辑/删除前的自动备份目录
  SM_NO_CLEAR=1               禁用首页清屏（保留终端滚动历史）
  SM_LOCALE=0                 关闭 locale 自适应；SM_LOCALE=<name> 指定 UTF-8 locale
  SM_WIDTH=68                 界面总宽（列数）
EOF
}

# ============================================================================
#  入口
# ============================================================================

# 显示宽度计算的字节表 + 自检（纯内建命令，开销可忽略；对所有模式生效）
_sm_bytes_init
_sm_width_selftest || true
_fit_width

# locale 自适应：在任何输出之前把本进程切到 UTF-8
# source 模式（SM_NO_ENTRY=1）跳过——改调用方的全局环境不是被加载者该做的事
if [[ "${SM_NO_ENTRY:-0}" != "1" ]]; then
    _ensure_utf8_locale
    _discover_main_conf || true
fi

# 解析参数（source 模式下 $# 是调用方的参数，不能当成自己的命令行来解析）
if [[ $# -ge 1 && "${SM_NO_ENTRY:-0}" != "1" ]]; then
    case "$1" in
        --help|-h)
            usage; exit 0 ;;
        --uninstall)
            shift; self_uninstall "$@"; exit $? ;;
        --install|install)
            shift
            self_install "$@"
            exit $?
            ;;
        -c)
            if [[ $# -lt 2 ]]; then
                ui_error "用法: sm.sh -c <command>"
                exit 1
            fi
            case "$2" in
                status)
                    if supervisor_alive; then
                        _svctl status
                    else
                        _report_not_alive
                        exit 1
                    fi
                    ;;
                install) action_install ;;
                boot)    action_boot ;;
                *) ui_error "未知命令: $2"; exit 1 ;;
            esac
            exit $?
            ;;
        --version|-V)
            echo "Supervisor Manager v$SM_VERSION"
            exit 0
            ;;
        *)
            ui_error "未知参数: $1"
            ui_info "执行 sm.sh --help 查看用法"
            exit 1
            ;;
    esac
fi

# 无参数：进入交互式菜单（SM_NO_ENTRY=1 时跳过，便于 source 加载）
if [[ "${SM_NO_ENTRY:-0}" != "1" ]]; then
    main_menu
fi || return 1
    fi
    [[ -z "$_SM_DAEMON_PID" || "$pid" == "$_SM_DAEMON_PID" ]] || return 1
    detected=$(_daemon_config "$pid") || detected=""
    if [[ -n "$detected" ]]; then
        [[ "$detected" == /* && "$detected" -ef "$SM_MAIN_CONF" ]] || return 1
    else
        [[ -n "$_SM_DAEMON_PID" ]] || return 1
    fi
    return 0
}

ui_menu() {
    local bare=0
    local zero_label="返回"
    # 选项前置开关：--bare 只画分隔线（首页看板模式）；--zero 自定义 0 号项文案
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --bare) bare=1; shift ;;
            --zero) zero_label="${2:-返回}"; shift 2 ;;
            *) break ;;
        esac
    done
    local title="${1:-}"; shift || true
    local options=("$@")
    while true; do
        if (( bare == 0 )); then
            ui_title "$title"
        else
            # bare 模式只画一条分隔线，把菜单与上方看板隔开
            ui_line '-' 
        fi
        local i=1
        for opt in "${options[@]}"; do
            printf "  ${C_CYAN}%2d${C_RESET}) %s\n" "$i" "$opt"
            ((i++))
        done
        echo -e "  ${C_GRAY}0) ${zero_label}${C_RESET}"
        echo
        local choice=""
        read -r -p "$(echo -e "${C_BOLD}请选择${C_RESET} [0-${#options[@]}]: ")" choice || return 1
        # 去除空白（用户可能多按空格）
        choice="${choice// /}"
        # 直接回车 = 不选择，静默重绘（不报错，避免误触时噪音）
        if [[ -z "$choice" ]]; then
            continue
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            ui_error "请输入数字"
            continue
        fi
        # 强制十进制，避免 "08" 被 (( )) / [[ -eq ]] 当作非法八进制
        if (( ${#choice} > 9 )); then ui_error "数字过大"; continue; fi
        choice=$((10#$choice))
        if (( choice < 0 || choice > ${#options[@]} )); then
            ui_error "超出范围 [0-${#options[@]}]"
            continue
        fi
        _SM_MENU_CHOICE="$choice"
        return 0
    done
}

# ============================================================================
#  系统检测
# ============================================================================

detect_pkgmgr() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown; fi
}

detect_init() {
    if [[ -d /run/systemd/system ]]; then echo systemd
    elif command -v rc-update >/dev/null 2>&1; then echo openrc
    else echo unknown; fi
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

require_root() {
    if ! is_root; then
        ui_error "此操作需要 root 权限，请使用 sudo 或切换到 root"
        ui_pause; return 1
    fi
    return 0
}

has_supervisord() { command -v supervisord >/dev/null 2>&1; }

# 判断 supervisord 是否可连通（socket 是否响应）
# 关键：不能用 supervisorctl status —— 任一进程非 RUNNING（FATAL/STOPPED/EXITED/STARTING）
# 时它返回退出码 3，会把"有异常进程"误判成"supervisord 未运行"。
# supervisorctl pid 才是可靠的存活探测：socket 通就返回 supervisord 的 PID 且退出 0。
supervisor_alive() {
    has_supervisord || return 1
    _svctl pid >/dev/null 2>&1
}

# 检测失败原因：区分"未启动"与"无权限访问 socket"
_supervisor_diag() {
    local err
    err=$(_svctl pid 2>&1 >/dev/null)
    if [[ "$err" == *"no such file"* || "$err" == *"refused"* || "$err" == *"不"* ]]; then
        echo "not_running"
    elif [[ "$err" == *"permission"* || "$err" == *"Permission"* || "$err" == *"EACCES"* || "$err" == *"denied"* ]]; then
        echo "no_permission"
    else
        echo "unknown"
    fi
}

# 统一的"supervisord 不可用"提示，按真实原因给出可操作建议
_report_not_alive() {
    local diag; diag=$(_supervisor_diag)
    case "$diag" in
        no_permission)
            ui_error "无权访问 supervisord socket（supervisord 可能正在运行）"
            ui_info "请用 sudo 运行本工具；不要随意放宽 socket 权限"
            ;;
        not_running)
            ui_error "supervisord 未运行"
            ui_info "请执行菜单 [2] 启动并配置开机自启"
            ;;
        *)
            ui_error "无法连接 supervisord"
            ui_info "排查: systemctl status supervisor / journalctl -u supervisor"
            ui_info "确认主配置 [supervisorctl] serverurl 与实际 socket 路径一致"
            ;;
    esac
}

# ============================================================================
#  模块: 安装
# ============================================================================

action_install() (
    require_root || return 1
    ui_title "安装 Supervisor"
    _lock_mutation || return 1
    (( ! _SM_CONF_AMBIGUOUS )) || { ui_error "请先明确配置路径"; return 1; }

    if has_supervisord; then
        ui_warn "已检测到 supervisord: $(supervisord --version 2>/dev/null | head -1)"
        if ! ui_confirm "是否重新安装/覆盖?" "n"; then return 0; fi
    fi

    local pkgmgr; pkgmgr=$(detect_pkgmgr)
    case "$pkgmgr" in
        apt)
            ui_info "使用 apt-get 安装..."
            apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y supervisor || return 1
            ;;
        yum)
            ui_info "使用 yum 安装（先装 EPEL）..."
            yum install -y supervisor || { yum install -y epel-release && yum install -y supervisor; } || return 1
            ;;
        dnf)
            ui_info "使用 dnf 安装（先装 EPEL）..."
            dnf install -y supervisor || { dnf install -y epel-release && dnf install -y supervisor; } || return 1
            ;;
        apk)
            ui_info "使用 apk 安装..."
            apk add --no-cache supervisor || return 1
            ;;
        pacman)
            ui_info "使用 pacman 安装..."
            pacman -S --noconfirm supervisor || return 1
            ;;
        unknown)
            ui_error "无法识别包管理器，请手动安装 supervisor 后重试"
            ui_info "可选: pip install supervisor （但需自建 systemd unit）"
            ui_pause; return 1
            ;;
    esac

    if ! has_supervisord; then
        ui_error "安装命令执行完毕但 supervisord 不可用，请检查输出"
        ui_pause; return 1
    fi
    ui_success "supervisor 已安装: $(supervisord --version 2>/dev/null | head -1)"

    _discover_main_conf || { ui_error "无法唯一识别安装后的主配置"; return 1; }
    mkdir -p "$SM_CONF_DIR" "$SM_LOG_DIR" "$SM_RUN_DIR" "$(dirname "$SM_MAIN_CONF")" || return 1
    local created=0

    if [[ ! -f "$SM_MAIN_CONF" ]]; then
        created=1
        ui_info "生成主配置: $SM_MAIN_CONF"
        # Generate a minimal config only for a fresh installation.
        # 兜底：echo_supervisord_conf 不存在（部分安装包不带）时手写最小可用配置
        if [[ ! -s "$SM_MAIN_CONF" ]]; then
            ui_warn "echo_supervisord_conf 不可用或输出为空，生成最小可用配置"
            (umask 077; cat > "$SM_MAIN_CONF") <<EOF
[unix_http_server]
file=$SM_RUN_DIR/supervisor.sock
chmod=0700

[supervisord]
logfile=$SM_LOG_DIR/supervisord.log
pidfile=$SM_RUN_DIR/supervisord.pid
childlogdir=$SM_LOG_DIR

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$SM_RUN_DIR/supervisor.sock

[include]
files = $SM_CONF_DIR/*.conf
EOF
        fi
    fi

    if (( created )); then
        _native_conf validate "$SM_MAIN_CONF" || { ui_error "新主配置校验失败"; return 1; }
    else
        ui_info "保留已有主配置及 include，不自动改写"
    fi

    ui_info "目录结构:"
    echo "  主配置:        $SM_MAIN_CONF"
    echo "  子进程配置目录: $SM_CONF_DIR"
    echo "  日志目录:      $SM_LOG_DIR"
    echo "  PID/Run 目录:  $SM_RUN_DIR"

    ui_pause
)

# ============================================================================
#  模块: 开机自启
# ============================================================================

action_boot() (
    require_root || return 1
    ui_title "配置开机自启"
    _lock_mutation || return 1
    _conf_ready || return 1

    if ! has_supervisord; then
        ui_error "尚未安装 supervisor，请先执行菜单 [1]"
        ui_pause; return 1
    fi

    local init; init=$(detect_init)
    case "$init" in
        systemd)
            # 用 systemctl cat 探测真实 unit 名，覆盖 /lib、/usr/lib、/etc 各发行版差异
            local svc_name=""
            local cand
            for cand in supervisor supervisord; do
                if systemctl cat "$cand" >/dev/null 2>&1; then
                    if [[ -n "$svc_name" ]] && [[ $(systemctl show "$svc_name" -p Id --value) != $(systemctl show "$cand" -p Id --value) ]]; then ui_error "多个 Supervisor unit，请手动处理"; return 1; fi
                    svc_name="$cand"
                fi
            done

            if [[ -z "$svc_name" ]]; then
                local sup_bin ctl_bin
                sup_bin=$(command -v supervisord)
                ctl_bin=$(command -v supervisorctl)
                if [[ -z "$sup_bin" || -z "$ctl_bin" ]]; then
                    ui_error "无法定位 supervisord/supervisorctl 可执行文件路径，无法生成 unit"
                    ui_pause; return 1
                fi
                _native_conf validate "$SM_MAIN_CONF" || return 1
                [[ "$SM_MAIN_CONF" != *[[:space:]%]* && "$sup_bin" != *[[:space:]%]* && "$ctl_bin" != *[[:space:]%]* ]] || { ui_error "路径含空白或 %，请手动创建 unit"; return 1; }
                ui_confirm "未找到原生 unit，是否创建 supervisor.service?" "n" || return 0
                cat > /etc/systemd/system/supervisor.service <<EOF
[Unit]
Description=Process Monitoring and Control Daemon (Supervisor)
After=network.target

[Service]
Type=simple
ExecStart=$sup_bin -n -c $SM_MAIN_CONF
ExecStop=$ctl_bin -c $SM_MAIN_CONF shutdown
RuntimeDirectory=supervisor
KillMode=control-group
TimeoutStopSec=120
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload || return 1
                svc_name=supervisor
            fi

            local cur_state=disabled cur_active=inactive
            systemctl is-enabled "$svc_name" >/dev/null 2>&1 && cur_state=enabled
            systemctl is-active "$svc_name"  >/dev/null 2>&1 && cur_active=active

            echo "  服务名:       $svc_name"
            echo "  开机自启:     $cur_state"
            echo "  运行状态:     $cur_active"
            echo

            if [[ "$cur_state" == "enabled" && "$cur_active" == "active" ]]; then
                ui_success "已开启开机自启且正在运行"
                if ui_confirm "是否禁用开机自启并停止?" "n"; then
                    systemctl disable --now "$svc_name" \
                        && ui_warn "已禁用并停止" \
                        || ui_error "禁用失败，请检查 systemctl 输出"
                fi
            else
                if ui_confirm "是否启用开机自启并立即启动?"; then
                    if ! systemctl enable --now "$svc_name"; then
                        ui_error "systemctl enable 失败"
                        ui_info "手动排查: systemctl status $svc_name"
                        ui_pause; return 1
                    fi
                    # 服务启动是异步的，轮询等待而不是立刻判定失败
                    local waited=0
                    while (( waited < 50 )); do
                        if systemctl is-active "$svc_name" >/dev/null 2>&1; then
                            break
                        fi
                        # 若已进入 failed 状态则提前退出
                        if systemctl is-failed "$svc_name" >/dev/null 2>&1; then
                            break
                        fi
                        sleep 0.2
                        ((waited++))
                    done

                    if systemctl is-active "$svc_name" >/dev/null 2>&1; then
                        ui_success "已启用并运行"
                        if supervisor_alive; then
                            ui_info "supervisorctl 连通性检查: 正常"
                        else
                            ui_warn "服务已启动但 supervisorctl 无法连通"
                            _report_not_alive
                        fi
                    else
                        ui_error "已 enable 但启动失败"
                        ui_info "排查命令:"
                        echo "    systemctl status $svc_name --no-pager -l"
                        echo "    journalctl -u $svc_name -n 50 --no-pager"
                        echo "    supervisord -n -c $SM_MAIN_CONF   # 前台试跑看报错"
                    fi
                fi
            fi
            ;;
        openrc)
            ui_info "检测到 OpenRC"
            rc-update add supervisor default 2>/dev/null || rc-update add supervisord default 2>/dev/null || {
                ui_error "OpenRC 添加开机自启失败，请手动执行 rc-update add supervisor default"
                ui_pause; return 1
            }
            ui_success "已加入 default 运行级"
            if ui_confirm "是否立即启动 Supervisor?"; then
                if [[ -x /etc/init.d/supervisor ]]; then rc-service supervisor start || return 1
                else rc-service supervisord start || return 1; fi
                supervisor_alive || { _report_not_alive; return 1; }
            fi
            ;;
        *)
            ui_error "无法识别 init 系统，建议手动写 /etc/rc.local 或 cron @reboot"
            ui_pause; return 1
            ;;
    esac
    ui_pause
)

# ============================================================================
#  模块: 状态
# ============================================================================

_list_proc_names() {
    if ! supervisor_alive; then return 0; fi
    # 原样列出第一列：包括 numprocs 实例（name:0/name:1）与组汇总（group:*）
    # supervisorctl 原生支持这些语法，无需也不能过滤
    _svctl status 2>/dev/null | awk '$2 ~ /^(STOPPED|STARTING|RUNNING|BACKOFF|STOPPING|EXITED|FATAL|UNKNOWN)$/ {print $1}'
}

# 读取状态原始输出（首页每轮菜单都会调用）
# 加 5 秒超时上限：socket 卡死时不会把整个菜单拖住；没有 timeout 命令则退化为直接调用
_supervisor_status_raw() {
    if command -v timeout >/dev/null 2>&1; then
        _svctl status 2>/dev/null
    else
        _svctl status 2>/dev/null
    fi
}

# 渲染进程状态表格（首页看板与独立查看共用）
# 返回 0=正常, 1=supervisord 不可用, 2=无受管进程
_render_status_table() {
    if ! has_supervisord; then
        echo -e "  ${C_YELLOW}supervisord 未安装${C_RESET}  → 请选择 [1] 安装"
        return 1
    fi
    if ! supervisor_alive; then
        local diag; diag=$(_supervisor_diag)
        if [[ "$diag" == "no_permission" ]]; then
            echo -e "  ${C_RED}无权访问 supervisord socket${C_RESET}  → 请用 sudo 运行"
        else
            echo -e "  ${C_RED}supervisord 未运行${C_RESET}  → 请选择 [2] 启动并配置开机自启"
        fi
        return 1
    fi

    local raw rc
    raw=$(_supervisor_status_raw); rc=$?
    # 124 = timeout 主动超时；此时 raw 为空，不能误报"暂无受管进程"
    # 注意：supervisorctl status 在有异常进程时本身返回 3，属正常，不能当错误处理
    if (( rc == 124 )); then
        echo -e "  ${C_RED}状态查询超时（supervisord 可能卡死）${C_RESET}  → 检查 $SM_LOG_DIR/supervisord.log"
        return 1
    fi
    if [[ -z "$raw" ]]; then
        echo -e "  ${C_GRAY}（暂无受管进程，选择 [3] 添加）${C_RESET}"
        return 2
    fi

    ( LC_ALL=C; _render_status_body "$raw" )
    return 0
}

# 状态表主体。必须在 LC_ALL=C 的子 shell 里调用——_pad_c 逐字节算显示宽度，
# 依赖 C locale 的字节语义；放在同一个子 shell 里还避免了每格 fork 一次。
#
# supervisorctl status 的列不固定，按状态分支解析：
#   name RUNNING   pid 12345, uptime 0:10:23
#   name RUNNING   pid 12345, uptime 1 day, 2:03:04
#   name FATAL     Exited too quickly (process log may have details)
#   name STOPPED   Sep 12 03:04 PM
#   name STARTING
_render_status_body() {
    local raw="$1"
    local line _n _st rest name state pid uptime color summary
    local total=0 running=0
    local -a lines=()
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        lines+=("$line")
        total=$((total + 1))
        read -r _n _st _ <<< "$line"
        [[ "$_st" == "RUNNING" ]] && running=$((running + 1))
    done <<< "$raw"

    # 颜色：C_* 里存的是字面量 "\033"，给 printf %s 用之前要换成真正的 ESC
    local E=$'\033' R G Y RD GY
    R="${C_RESET//\\033/$E}";  G="${C_GREEN//\\033/$E}"
    Y="${C_YELLOW//\\033/$E}"; RD="${C_RED//\\033/$E}"
    GY="${C_GRAY//\\033/$E}"

    if (( running == total )); then
        summary="共 ${total} 个，${G}全部运行中${R}"
    else
        summary="共 ${total} 个，${G}运行 ${running}${R}，${RD}异常 $((total - running))${R}"
    fi
    # 整个函数已在 LC_ALL=C 子 shell 里，直接调 _pad_c 读 _SM_PAD，不走 $( )（每行省 3 次 fork）
    local p1 p2 p3
    _pad_c "进程状态" 10; printf '  %s%s\n' "$_SM_PAD" "$summary"

    _pad_c "名称" "$_SM_W_NAME";  p1=$_SM_PAD
    _pad_c "状态" "$_SM_W_STATE"; p2=$_SM_PAD
    _pad_c "PID"  "$_SM_W_PID";   p3=$_SM_PAD
    printf '  %s  %s  %s  %s\n' "$p1" "$p2" "$p3" "运行时长"
    _rule "$_SM_W_NAME";  p1=$_SM_PAD
    _rule "$_SM_W_STATE"; p2=$_SM_PAD
    _rule "$_SM_W_PID";   p3=$_SM_PAD
    _rule "$_SM_W_UP"
    printf '  %s  %s  %s  %s\n' "$p1" "$p2" "$p3" "$_SM_PAD"

    for line in "${lines[@]}"; do
        read -r name state rest <<< "$line"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        pid="-"; uptime="-"
        if [[ "$state" == "RUNNING" && "$rest" == "pid "* ]]; then
            # rest = "pid 101, uptime 0:10:23" / "pid 102, uptime 1 day, 2:03:04"
            # rest 的字段：1=pid 2=<PID>, 3=uptime 4...=<时长>
            set -- $rest
            pid="${2:-}"; pid="${pid%,}"
            [[ -z "$pid" ]] && pid="-"
            uptime="${*:4}"
            # "1 day, 2:03:04" / "26 days, 3:04:05" 压成 "1d 2:03:04" / "26d 3:04:05"，
            # 最长 "365d 23:59:59" 也能放进 16 列（原样 "365 days, 23:59:59" 会撑出表格）
            uptime="${uptime// days, /d }"
            uptime="${uptime// day, /d }"
        else
            [[ -n "$rest" ]] && uptime="$rest"
        fi

        case "$state" in
            RUNNING)                              color="$G" ;;
            FATAL|STOPPED)                        color="$RD" ;;
            STARTING|STOPPING|BACKOFF)            color="$Y" ;;
            *)                                    color="$GY" ;;
        esac
        _pad_c "$name"  "$_SM_W_NAME";  p1=$_SM_PAD
        _pad_c "$state" "$_SM_W_STATE"; p2=$_SM_PAD
        _pad_c "$pid"   "$_SM_W_PID";   p3=$_SM_PAD
        printf '  %s  %s%s%s  %s  %s\n' "$p1" "$color" "$p2" "$R" "$p3" "$uptime"
    done
}

# 清屏（仅 tty 下生效；SM_NO_CLEAR=1 可禁用，便于保留滚动历史）
_clear_screen() {
    if [[ "${SM_NO_CLEAR:-0}" != "1" ]] && [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
}

# 独立的"查看状态"屏（首页已自带看板，交互菜单不再用它）
# 保留原因：source 加载本脚本（SM_NO_ENTRY=1）后，其他脚本可直接调用它打印带标题的状态屏
action_status() {
    ui_title "进程状态"
    _render_status_table
    ui_pause
}


# ============================================================================
#  模块: 添加守护进程
# ============================================================================


# Private backup storage and an advisory lock for cooperating SVM sessions.
_private_dir() {
    local dir="$SM_BACKUP_DIR" mode
    [[ "$dir" == /* && ! -L "$dir" ]] || return 1
    (umask 077; mkdir -p -- "$dir") || return 1
    [[ -d "$dir" && ! -L "$dir" && $(stat -c %u -- "$dir") == "$EUID" ]] || return 1
    mode=$(stat -c %a -- "$dir") || return 1
    if [[ "$dir" == /var/backups/supervisor-manager && "$mode" == 755 ]]; then
        chmod 0700 -- "$dir" || return 1
        mode=700
    fi
    [[ "$mode" == 700 ]] || { ui_error "备份目录权限必须为 0700: $dir" >&2; return 1; }
}

_lock_mutation() {
    require_root || return 1
    _private_dir || { ui_error "无法建立安全备份目录，取消操作"; return 1; }
    command -v flock >/dev/null 2>&1 || { ui_error "缺少 flock（util-linux）"; return 1; }
    [[ ! -L "$SM_BACKUP_DIR/.lock" ]] || return 1
    exec 9>>"$SM_BACKUP_DIR/.lock" || return 1
    flock -n 9 || { ui_error "另一 SVM 会话正在修改配置"; return 1; }
}

_safe_target() {
    local file="$1" dir owner mode
    [[ "$file" == /* && ! -L "$file" && ! -d "$file" ]] || return 1
    dir=$(dirname -- "$file")
    [[ -d "$dir" ]] || return 1
    owner=$(stat -Lc %u -- "$dir") || return 1
    mode=$(stat -Lc %a -- "$dir") || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    if [[ -e "$file" ]]; then
        [[ -f "$file" && $(stat -c %u -- "$file") == "$EUID" ]] || return 1
    fi
}

_atomic_publish() {
    local src="$1" dst="$2" tmp mode=0600
    _safe_target "$dst" || { ui_error "拒绝不安全的写入目标: $dst"; return 1; }
    tmp=$(mktemp "$(dirname -- "$dst")/.svm.XXXXXXXX") || return 1
    if [[ -f "$dst" ]]; then mode=$(stat -c %a -- "$dst") || { rm -f -- "$tmp"; return 1; }; fi
    if ! cat -- "$src" > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$dst"; then
        rm -f -- "$tmp"; return 1
    fi
}

_reread_groups() {
    local out line
    out=$(_svctl reread 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "No config updates to processes" ]] && continue
        if [[ "$line" =~ ^([^[:space:]:]+):[[:space:]](available|changed|disappeared)$ ]]; then
            [[ "${BASH_REMATCH[1]}" != all && "${BASH_REMATCH[1]}" != -* ]] || return 1
            printf '%s\n' "${BASH_REMATCH[1]}"
        else
            printf '无法识别 reread 输出: %s\n' "$line" >&2; return 1
        fi
    done <<< "$out"
}

_tx_begin() {
    _conf_ready || return 1
    _lock_mutation || return 1
    _TX_TARGET="$1"; _TX_BACKUP=""; _TX_STAGE=""; _TX_DIRTY=0
    _TX_ONLINE=0; _TX_APPLY=0; _TX_MAIN_RESTART=0; _TX_GROUPS=""; _TX_MODE=0600
    _safe_target "$_TX_TARGET" || { ui_error "不安全的目标: $_TX_TARGET"; return 1; }
    _native_conf validate "$SM_MAIN_CONF" || { ui_error "现有配置无效，请先手动恢复"; return 1; }
    if supervisor_alive; then
        _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }
        local pending
        pending=$(_reread_groups) || return 1
        [[ -z "$pending" ]] || {
            ui_error "已有未应用的配置修改，请先使用菜单 [9] 或手工处理"
            printf '%s\n' "$pending"; return 1;
        }
        _TX_ONLINE=1
    elif [[ -n "$_SM_DAEMON_PID" ]] || pgrep -x supervisord >/dev/null 2>&1; then
        ui_error "发现运行中的 Supervisor 但无法确认连接，拒绝写入"; return 1
    fi
    if [[ -f "$_TX_TARGET" ]]; then
        _TX_MODE=$(stat -c %a -- "$_TX_TARGET") || return 1
        _TX_BACKUP=$(_backup_file "$_TX_TARGET") || { ui_error "备份失败，取消修改"; return 1; }
        ui_info "已备份: $_TX_BACKUP"
    fi
    _TX_STAGE=$(mktemp "$SM_BACKUP_DIR/.stage.XXXXXXXX") || return 1
    trap '_tx_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -n "$_TX_BACKUP" ]]; then cat -- "$_TX_BACKUP" > "$_TX_STAGE" || return 1; fi
}

_tx_cleanup() {
    local rc=$?
    trap - EXIT
    trap '' INT TERM
    if (( _TX_DIRTY )); then
        ui_warn "操作未提交，恢复磁盘配置"
        local restored=1
        if [[ -n "$_TX_BACKUP" ]]; then
            if _atomic_publish "$_TX_BACKUP" "$_TX_TARGET"; then chmod "$_TX_MODE" -- "$_TX_TARGET" || restored=0; else restored=0; fi
        else
            rm -f -- "$_TX_TARGET" || restored=0
        fi
        if (( ! restored )); then
            ui_error "自动恢复失败！目标: $_TX_TARGET；备份: $_TX_BACKUP"
        elif (( _TX_ONLINE )); then
            if (( _TX_MAIN_RESTART )); then
                _restart_supervisor || ui_error "磁盘已恢复，但服务重启失败，请人工检查"
            else
                local groups g
                groups=$(_reread_groups) || { ui_error "磁盘已恢复，但 reread 失败"; groups=""; }
                if (( _TX_APPLY )) && [[ -n "$groups" ]]; then
                    while IFS= read -r g; do
                        [[ -n "$g" ]] || continue
                        if grep -Fxq -- "$g" <<< "$_TX_GROUPS"; then
                            _svctl update "$g" || ui_error "组 $g 运行态恢复失败"
                        else
                            ui_warn "未自动应用无关组 $g"
                        fi
                    done <<< "$groups"
                    ui_warn "运行态恢复为尽力而为；请复核原手动启停状态"
                fi
            fi
        fi
        (( rc == 0 )) && rc=1
    fi
    [[ -z "$_TX_STAGE" ]] || rm -f -- "$_TX_STAGE"
    exit "$rc"
}

_tx_publish() {
    if [[ -n "$_TX_BACKUP" ]]; then
        cmp -s -- "$_TX_TARGET" "$_TX_BACKUP" || { ui_error "配置已被外部修改"; return 1; }
    else
        [[ ! -e "$_TX_TARGET" && ! -L "$_TX_TARGET" ]] || { ui_error "目标已存在"; return 1; }
    fi
    _TX_DIRTY=1
    _atomic_publish "$_TX_STAGE" "$_TX_TARGET"
}

_tx_apply() {
    _native_conf validate "$SM_MAIN_CONF" || return 1
    if (( _TX_ONLINE )); then
        _TX_GROUPS=$(_reread_groups) || return 1
        if [[ -n "$_TX_GROUPS" ]]; then
            local -a groups=()
            local g remaining
            while IFS= read -r g; do [[ -n "$g" ]] && groups+=("$g"); done <<< "$_TX_GROUPS"
            ui_info "仅应用变更组: ${groups[*]}"
            _TX_APPLY=1
            _svctl update "${groups[@]}" || return 1
            remaining=$(_reread_groups) || return 1
            [[ -z "$remaining" ]] || { ui_error "仍有未应用的配置变更"; return 1; }
        fi
    else
        ui_info "配置已通过离线解析；下次启动时生效"
    fi
    _TX_DIRTY=0
}

_restart_supervisor() {
    local init svc="" cand waited=0
    init=$(detect_init)
    case "$init" in
        systemd)
            for cand in supervisor supervisord; do
                if systemctl cat "$cand" >/dev/null 2>&1; then
                    if [[ -n "$svc" ]] && [[ $(systemctl show "$svc" -p Id --value) != $(systemctl show "$cand" -p Id --value) ]]; then
                        ui_error "存在多个 Supervisor unit，请手动重启"; return 1
                    fi
                    svc="$cand"
                fi
            done
            [[ -n "$svc" ]] || return 1
            systemctl restart "$svc" || return 1;;
        openrc)
            for cand in supervisor supervisord; do
                [[ -x "/etc/init.d/$cand" ]] || continue
                [[ -z "$svc" ]] || return 1
                svc="$cand"
            done
            [[ -n "$svc" ]] || return 1
            rc-service "$svc" restart || return 1;;
        *) ui_error "未知 init，请手动重启"; return 1;;
    esac
    while (( waited < 20 )); do
        supervisor_alive && return 0
        sleep 0.5; ((waited++))
    done
    return 1
}

action_add() (
    require_root || return 1
    ui_title "添加守护进程"

    if ! has_supervisord; then
        ui_error "尚未安装 supervisor"
        ui_pause; return 1
    fi

    echo -e "${C_GRAY}按提示逐步填写，留空使用默认值。Ctrl+C 取消。${C_RESET}"
    echo

    local name command user directory autostart autorestart stdout_log stderr_log priority env_str

    # 所有后续输入统一做 EOF 保护：任一 read 失败立即中止，避免写出空字段配置
    name=$(_ask_or_abort "进程名称(英文，作为program段名)") || { ui_pause; return 0; }

    if [[ -z "$name" ]]; then
        ui_error "名称不能为空"
        ui_pause; return 1
    fi
    # 进程名会成为 [program:x] 段名，必须符合 supervisor 命名规则
    if ! [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || [[ "$name" == all ]]; then
        ui_error "名称只能包含字母、数字、下划线、点、连字符（不含空格/斜杠/冒号）"
        ui_info "示例: myapp / web_api / worker-01"
        ui_pause; return 1
    fi
    # 写入位置必须以 include 为准：目录和后缀都要对，否则 supervisord 永远不会加载
    _conf_ready || return 1
    _preferred_conf_target "$name" || return 1
    local target="$_SM_TARGET_FILE"
    local conf_dir="${target%/*}"
    local name_rc=0
    _program_exists "$name" || name_rc=$?
    (( name_rc == 1 )) || { ui_error "名称重复或解析失败"; return 1; }
    if [[ -e "$target" || -L "$target" ]]; then
        ui_error "已存在同名进程 [program:$name]，请改用菜单 [8] 编辑"
        ui_pause; return 1
    fi

    command=$(_ask_or_abort "启动命令" "/usr/local/bin/$name") || { ui_pause; return 0; }
    user=$(_ask_or_abort "运行用户" "root") || { ui_pause; return 0; }
    directory=$(_ask_or_abort "工作目录" "/") || { ui_pause; return 0; }
    autostart=$(_ask_or_abort "随supervisor启动(y/n)" "y") || { ui_pause; return 0; }
    autorestart=$(_ask_or_abort "自动重启(true/unexpected/false)" "true") || { ui_pause; return 0; }
    priority=$(_ask_or_abort "启动优先级(数字越小越早)" "999") || { ui_pause; return 0; }
    stdout_log=$(_ask_or_abort "stdout日志路径" "$SM_LOG_DIR/$name.log") || { ui_pause; return 0; }
    stderr_log=$(_ask_or_abort "stderr日志路径" "$SM_LOG_DIR/$name-error.log") || { ui_pause; return 0; }
    env_str=$(_ask_or_abort "环境变量(KEY1=val1,KEY2=val2 可空)" "") || { ui_pause; return 0; }

    # command 是必填项，空配置会让进程直接 FATAL
    if [[ -z "$command" ]]; then
        ui_error "启动命令不能为空"
        ui_pause; return 1
    fi
    # 优先级必须是非负整数
    if ! [[ "$priority" =~ ^[0-9]+$ ]]; then
        ui_warn "优先级 '$priority' 非数字，回退为默认 999"
        priority=999
    fi
    # 日志路径建议绝对路径（supervisord 的工作目录与当前 shell 不同）
    if [[ "$stdout_log" != /* || "$stderr_log" != /* ]]; then
        ui_warn "日志路径建议使用绝对路径，相对路径会相对 supervisord 的启动目录解析"
        if ! ui_confirm "仍要继续?" "n"; then
            ui_warn "已取消"; ui_pause; return 0
        fi
    fi

    autostart=$(_to_bool "$autostart")
    case "$autorestart" in true|y|yes) autorestart=true;; unexpected) ;; false|n|no) autorestart=false;; *) ui_error "无效重启策略"; return 1;; esac
    id "$user" >/dev/null 2>&1 || { ui_error "运行用户不存在"; return 1; }
    [[ -d "$directory" && "$directory" == /* ]] || { ui_error "工作目录必须为存在的绝对路径"; return 1; }

    ui_title "预览配置"
    echo "[program:$name]"
    echo "command=$command"
    echo "directory=$directory"
    echo "user=$user"
    echo "autostart=$autostart"
    echo "autorestart=$autorestart"
    echo "priority=$priority"
    echo "stdout_logfile=$stdout_log"
    echo "stderr_logfile=$stderr_log"
    [[ -n "$env_str" ]] && echo "environment=（已隐藏）"
    echo

    if ! ui_confirm "确认写入并加载?"; then
        ui_warn "已取消"; ui_pause; return 0
    fi

    _tx_begin "$target" || return 1
    [[ -z "$_TX_BACKUP" ]] || { ui_error "目标已存在"; return 1; }
    name_rc=0; _program_exists "$name" || name_rc=$?
    (( name_rc == 1 )) || return 1
    mkdir -p -- "$(dirname -- "$stdout_log")" "$(dirname -- "$stderr_log")" || return 1
    {
        printf '%s\n' "[program:$name]" "command=$command" "directory=$directory" "user=$user"
        printf '%s\n' "autostart=$autostart" "autorestart=$autorestart" "priority=$priority"
        printf '%s\n' "stdout_logfile=$stdout_log" "stderr_logfile=$stderr_log"
        printf '%s\n' 'stdout_logfile_maxbytes=8MB' 'stdout_logfile_backups=3'
        printf '%s\n' 'stderr_logfile_maxbytes=8MB' 'stderr_logfile_backups=3'
        printf '%s\n' 'stopasgroup=true' 'killasgroup=true'
        if [[ -n "$env_str" ]]; then printf '%s\n' "environment=$env_str"; fi
    } > "$_TX_STAGE" || return 1
    _tx_publish || return 1
    local files
    files=$(_conf_source_files) || return 1
    grep -Fxq -- "$target" <<< "$files" || { ui_error "新文件未被 include 匹配"; return 1; }
    _tx_apply || return 1
    ui_success "配置添加完成: $target"
    if (( _TX_ONLINE )); then
        if [[ "$autostart" == false ]] && ui_confirm "是否立即启动?" "n"; then
            _svctl start "$name" || { ui_error "配置已加载，但启动失败"; return 1; }
        fi
        _svctl status "$name" || ui_warn "配置已加载，进程未处于 RUNNING，请查看日志"
    fi
    ui_pause

)

# ============================================================================
#  模块: 启停重启
# ============================================================================

# 选择操作目标，结果写入全局 _SM_TARGET
# 注意：不能用 $(...) 取值 —— ui_menu 会把选项列表打印到 stdout，
# 被命令替换捕获后 target 会变成"整段菜单文本 + 进程名"，supervisorctl 必然报 no such process。
_promote_target() {
    local op="$1"
    _SM_TARGET=""
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(_list_proc_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        ui_error "当前没有受管进程"
        ui_pause; return 1
    fi
    local options=()
    for n in "${names[@]}"; do options+=("$n"); done
    options+=("全部 (all)")
    if ! ui_menu "选择要${op}的进程" "${options[@]}"; then return 1; fi
    local choice="$_SM_MENU_CHOICE"
    if [[ "$choice" -eq 0 ]]; then return 1; fi
    if [[ "$choice" -eq $(( ${#names[@]} + 1 )) ]]; then
        _SM_TARGET="all"
    else
        _SM_TARGET="${names[$((choice-1))]}"
    fi
    return 0
}

action_start()   { _action_ctl "启动" "start"; }
action_stop()    { _action_ctl "停止"  "stop"; }
action_restart() { _action_ctl "重启"  "restart"; }

_action_ctl() {
    local op="$1"; local cmd="$2"
    ui_title "${op}进程"
    if ! supervisor_alive; then
        _report_not_alive; ui_pause; return 1
    fi
    _promote_target "$op" || { ui_pause; return 0; }
    local target="$_SM_TARGET"
    _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }
    if [[ "$target" == all && "$cmd" != start ]]; then ui_confirm "确认${op}全部进程?" "n" || return 0; fi
    [[ -n "$target" ]] || { ui_warn "未选择目标"; ui_pause; return 0; }
    ui_info "执行 supervisorctl $cmd $target ..."
    if _svctl "$cmd" "$target"; then
        ui_success "${op}完成"
    else
        ui_error "${op}失败"
    fi
    ui_pause
}

# ============================================================================
#  模块: 日志
# ============================================================================

action_log() {
    ui_title "查看日志"
    if ! supervisor_alive; then
        _report_not_alive; ui_pause; return 1
    fi
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(_list_proc_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        ui_error "没有受管进程"; ui_pause; return 1
    fi
    if ! ui_menu "选择进程" "${names[@]}"; then ui_pause; return 0; fi
    local choice="$_SM_MENU_CHOICE"
    [[ "$choice" -eq 0 ]] && { ui_pause; return 0; }
    local name="${names[$((choice-1))]}"

    local actions=(
        "查看 stdout 末尾 (tail)"
        "查看 stderr 末尾 (tail)"
        "实时跟随 stdout (tail -f)"
        "实时跟随 stderr (tail -f)"
        "只读查看 stdout_logfile"
        "只读查看 stderr_logfile"
    )
    if ! ui_menu "选择日志动作 [$name]" "${actions[@]}"; then ui_pause; return 0; fi
    local act="$_SM_MENU_CHOICE"
    [[ "$act" -eq 0 ]] && { ui_pause; return 0; }

    case "$act" in
        1) _svctl tail "$name" stdout ;;
        2) _svctl tail "$name" stderr ;;
        3) echo -e "${C_GRAY}Ctrl+C 退出${C_RESET}"; _svctl tail -f "$name" stdout ;;
        4) echo -e "${C_GRAY}Ctrl+C 退出${C_RESET}"; _svctl tail -f "$name" stderr ;;
        5|6)
            local key
            if [[ "$act" -eq 5 ]]; then key=stdout_logfile; else key=stderr_logfile; fi
            local file
            file=$(_lookup_key "$name" "$key")

            if [[ -z "$file" || "$file" != /* || ! -f "$file" ]]; then
                ui_warn "实际日志不存在或不可用，建议使用 Supervisor tail"
            else
                tail -n 100 -- "$file"
            fi
            ;;
    esac
    ui_pause
}

# ============================================================================
#  模块: 编辑/删除/重载/主配置
# ============================================================================

# 文件指纹：判断"编辑到底有没有改内容"，避免没改也提示重载
_file_sig() {
    if [[ -f "$1" ]]; then
        cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'
    else
        echo "missing"
    fi
}

# 编辑前备份，成功则输出备份路径；失败返回 1（调用方只 warn，不阻塞编辑）
_backup_file() {
    local file="$1" dest
    [[ -f "$file" && ! -L "$file" ]] || return 1
    _private_dir || return 1
    dest=$(mktemp "$SM_BACKUP_DIR/${file##*/}.XXXXXXXX") || return 1
    if ! cat -- "$file" > "$dest" || ! chmod 0600 "$dest"; then rm -f -- "$dest"; return 1; fi
    printf '%s\n' "$dest"
}

# 执行 reread + update，返回 0=成功 1=失败
# 关键：supervisorctl reread 遇到配置语法错误会打印 ERROR 并以非 0 退出，
# 若忽略返回值，工具会继续打印"重载完成"，用户以为改动生效了——实际 supervisord
# 仍在用内存里的旧配置。这是"编辑配置后没反应"最常见的原因。
_do_reload() {
    local out rc
    out=$(_svctl reread 2>&1); rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out"
    if (( rc != 0 )) || [[ "$out" == *ERROR* ]]; then
        ui_error "reread 失败：配置有语法错误，本次改动未生效"
        ui_info "常见原因：段名应为 [program:name]、缺 command、引号/方括号不配对"
        ui_info "supervisord 仍在运行改动前的配置，进程未受影响"
        return 1
    fi

    out=$(_svctl update 2>&1); rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out"
    if (( rc != 0 )) || [[ "$out" == *ERROR* ]]; then
        ui_error "update 失败：新配置未完全应用"
        return 1
    fi
    return 0
}

# 列出 supervisord 实际会加载的进程配置文件（完整路径，已去重）
# 依据 include，而不是硬编码 SM_CONF_DIR —— 详见"配置文件定位"一节
_list_conf_files() {
    local f list
    list=$(_conf_source_files) || return 1
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" && ! "$f" -ef "$SM_MAIN_CONF" ]] || continue
        printf '%s\n' "$f"
    done <<< "$list"
}

# 列表为空时的诊断：把"为什么空"讲清楚，而不是只说目录为空
_conf_diag_empty() {
    ui_info "主配置:   ${SM_MAIN_CONF}（$( [[ -f "$SM_MAIN_CONF" ]] && echo 存在 || echo '不存在')）"
    local pats
    pats=$(_conf_include_patterns "$SM_MAIN_CONF" 2>/dev/null | tr '\n' ' ')
    if [[ -n "${pats// /}" ]]; then
        ui_info "[include] files: $pats"
        ui_info "展开后没有匹配到文件，检查该路径/后缀是否写对（ls 一下）"
    else
        ui_warn "主配置里没有可解析的 [include] files"
        ui_info "进程可能直接写在主配置中——这种情况请用菜单 [11] 编辑主配置"
    fi
    ui_info "也可用 SM_MAIN_CONF=... 或 SM_CONF_DIR=... 指定实际路径后重试"
}

action_edit() (
    require_root || return 1
    ui_title "编辑进程配置"
    local list f file
    list=$(_list_conf_files) || return 1
    local -a files=()
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done <<< "$list"
    if (( ${#files[@]} == 0 )); then _conf_diag_empty; ui_pause; return 1; fi
    ui_menu "选择配置文件（可能包含多个进程）" "${files[@]}" || return 0
    [[ "$_SM_MENU_CHOICE" != 0 ]] || return 0
    file="${files[$((_SM_MENU_CHOICE-1))]}"
    _tx_begin "$file" || return 1
    _open_editor "$_TX_STAGE" || { ui_error "编辑器退出异常，未修改正式配置"; return 1; }
    if cmp -s -- "$_TX_STAGE" "$_TX_BACKUP"; then ui_info "配置未改变"; return 0; fi
    ui_confirm "确认保存并应用配置?" "n" || return 0
    _tx_publish || return 1
    _tx_apply || return 1
    ui_success "配置修改完成"
    ui_pause
)

# 从一个配置文件里提取受管实体名（[program:x] / [group:x]）
# 一个 .conf 里可能定义多个 program，直接拿文件名去 stop 会 no such process
_conf_entity_names() {
    local file="$1"
    awk '
        /^[[:space:]]*\[(program|group):/ {
            line = $0
            sub(/^[[:space:]]*\[/, "", line)
            sub(/\].*$/, "", line)
            sub(/^(program|group):[[:space:]]*/, "", line)
            if (length(line) > 0) print line
        }
    ' "$file" 2>/dev/null
}

action_delete() (
    require_root || return 1
    ui_title "删除整个配置文件"
    local list f file sections
    list=$(_list_conf_files) || return 1
    local -a files=()
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done <<< "$list"
    if (( ${#files[@]} == 0 )); then _conf_diag_empty; return 1; fi
    ui_menu "选择整个配置文件" "${files[@]}" || return 0
    [[ "$_SM_MENU_CHOICE" != 0 ]] || return 0
    file="${files[$((_SM_MENU_CHOICE-1))]}"
    _tx_begin "$file" || return 1
    [[ -n "$_TX_BACKUP" ]] || return 1
    sections=$(_native_conf entities "$_TX_BACKUP") || return 1
    ui_warn "即将删除 $file 的全部段（不是单个进程）:"
    printf '%s\n' "$sections"
    ui_confirm "确认删除整个文件并停止受影响进程组?" "n" || return 0
    cmp -s -- "$file" "$_TX_BACKUP" || { ui_error "配置已被外部修改"; return 1; }
    _TX_DIRTY=1
    rm -- "$file" || return 1
    _tx_apply || return 1
    ui_success "已删除配置文件: $file"
    ui_pause
)

action_reload() (
    _lock_mutation || return 1
    ui_title "全局重载 Supervisor 配置"
    _check_daemon_identity || { ui_error "无法验证本机 Supervisor 实例"; return 1; }
    _native_conf validate "$SM_MAIN_CONF" || return 1
    ui_warn "全局 update 可能重启所有存在未应用修改的进程组"
    ui_confirm "确认全局应用?" "n" || return 0
    if _do_reload; then
        ui_success "重载完成"; _render_status_table
    else
        ui_error "重载失败或部分应用，请检查实际运行状态"
        ui_pause; return 1
    fi
    ui_pause
)

action_edit_main() (
    require_root || return 1
    ui_title "编辑主 supervisord.conf"
    _conf_ready || return 1
    _tx_begin "$SM_MAIN_CONF" || return 1
    _open_editor "$_TX_STAGE" || return 1
    if cmp -s -- "$_TX_STAGE" "$_TX_BACKUP"; then ui_info "配置未改变"; return 0; fi
    ui_warn "主配置变更可能影响全部进程；重启会中断业务"
    ui_confirm "确认保存主配置?" "n" || return 0
    _tx_publish || return 1
    _native_conf validate "$SM_MAIN_CONF" || return 1
    if (( _TX_ONLINE )) && ui_confirm "立即重启 Supervisor 并检查连接?" "n"; then
        _TX_MAIN_RESTART=1
        _restart_supervisor || return 1
        _TX_DIRTY=0
        ui_success "已保存并重启"
    else
        _TX_DIRTY=0
        ui_warn "主配置已保存且通过解析；全局设置需下次重启才能生效"
    fi
    ui_pause
)

# ============================================================================
#  主菜单
# ============================================================================

main_menu() {
    while true; do
        _discover_main_conf || true
        # 首页 = 状态看板 + 菜单（一屏看完，不用再单独进"查看状态"）
        # _SM_SKIP_CLEAR=1 用于跳过本次清屏（看日志回来时保留刚读到的内容）
        if [[ "${_SM_SKIP_CLEAR:-0}" == "1" ]]; then
            _SM_SKIP_CLEAR=0
            echo
        else
            _clear_screen
        fi
        # locale 自适应的一次性提示：放在清屏之后，否则首屏会被刷掉
        if [[ -n "$_SM_LOCALE_NOTE" ]]; then
            echo -e "$_SM_LOCALE_NOTE"
            _SM_LOCALE_NOTE=""
        fi
        ui_title "Supervisor Manager v$SM_VERSION"
        _render_status_table

        if ! ui_menu --bare --zero "退出" "" \
            "安装 Supervisor" \
            "配置开机自启" \
            "添加守护进程" \
            "启动进程" \
            "停止进程" \
            "重启进程" \
            "查看/跟随日志" \
            "编辑进程配置" \
            "重载 supervisor 配置 (reread+update)" \
            "删除守护进程" \
            "编辑主 supervisord.conf"; then
            # EOF（Ctrl-D / 管道结束）
            echo "再见"; exit 0
        fi
        local choice="$_SM_MENU_CHOICE"
        case "$choice" in
            1)  action_install ;;
            2)  action_boot ;;
            3)  action_add ;;
            4)  action_start ;;
            5)  action_stop ;;
            6)  action_restart ;;
            7)  action_log; _SM_SKIP_CLEAR=1 ;;
            8)  action_edit ;;
            9)  action_reload ;;
            10) action_delete ;;
            11) action_edit_main ;;
            0)  echo "再见"; exit 0 ;;
        esac
    done
}

# ============================================================================
#  Self-install: 把脚本自身安装到 /usr/local/bin/svm（或自定义名字）
# ============================================================================

# 检测 PATH 中的某个命令是否是本工具自身
# 注意：特征串不带版本号——否则新版脚本检测旧版安装会误判为"非本工具"
_is_self_cmd() {
    local cmd_path="$1"
    [[ -f "$cmd_path" && ! -L "$cmd_path" ]] || return 1
    grep -q '^#  sm.sh - Supervisor Manager (interactive shell, menu-driven)' "$cmd_path" &&
        grep -q '^SM_VERSION="[0-9]' "$cmd_path"
}

# 提取已安装版本的版本号（读 SM_VERSION="x.y.z" 行）
_get_self_version() {
    local cmd_path="$1"
    [[ -f "$cmd_path" ]] || return 1
    sed -n 's/^SM_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$cmd_path" 2>/dev/null | head -1
}

# 寻找一个可用的命令名（svm 优先，冲突则尝试 svmgr/supmgr）
_pick_install_name() {
    local prefer="$1"
    local candidates=("$prefer")
    [[ "$prefer" != "svm" ]] && candidates+=("svm")
    candidates+=("svmgr" "supmgr" "supvmgr")

    local existing
    for name in "${candidates[@]}"; do
        existing=$(command -v "$name" 2>/dev/null || true)
        if [[ -z "$existing" ]]; then
            echo "$name"; return 0
        fi
        # 已存在，但是否是本工具自身？
        if _is_self_cmd "$existing"; then
            echo "$name"; return 0
        fi
    done
    # 全都冲突
    echo ""
    return 1
}

self_install() {
    local install_name="svm"
    local install_path="/usr/local/bin"
    local force=0

    # 解析剩余参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    ui_error "--as 需要一个命令名参数"
                    return 1
                fi
                install_name="$2"; shift 2 ;;
            --path)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    ui_error "--path 需要一个目录参数"
                    return 1
                fi
                install_path="$2"; shift 2 ;;
            --force|-f)
                force=1; shift ;;
            --help|-h)
                cat <<EOF
用法: sm.sh --install [--as NAME] [--path PATH] [--force]

  --as NAME      指定安装后的命令名（默认 svm，冲突则自动尝试 svmgr/supmgr）
  --path PATH    安装目录（默认 /usr/local/bin）
  --force        跳过冲突检测，强制覆盖

示例:
  sm.sh --install                    # 安装为 svm（冲突则降级）
  sm.sh --install --as svmgr         # 强制安装为 svmgr
  sm.sh --install --path /opt/bin    # 装到 /opt/bin/svm
EOF
                return 0
                ;;
            *) ui_error "未知参数: $1"; return 1 ;;
        esac
    done

    require_root || return 1

    ui_title "Self-install"

    # 安装目录检查
    if [[ ! -d "$install_path" ]]; then
        ui_error "安装目录不存在: $install_path"
        ui_info "请先 mkdir -p $install_path 或换一个目录"
        return 1
    fi

    [[ "$install_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { ui_error "无效命令名"; return 1; }
    [[ "$install_path" == /* ]] || { ui_error "安装目录必须为绝对路径"; return 1; }
    local final_name="$install_name" target src existing candidate backup tmp version
    local -a candidates=("$install_name")
    [[ "$install_name" != svm ]] || candidates+=(svmgr supmgr supvmgr)
    if (( ! force )); then
        final_name=""
        for candidate in "${candidates[@]}"; do
            if _is_self_cmd "$install_path/$candidate"; then final_name="$candidate"; break; fi
        done
        if [[ -z "$final_name" ]]; then
            for candidate in "${candidates[@]}"; do
                existing=$(command -v "$candidate" 2>/dev/null || true)
                [[ -z "$existing" && ! -e "$install_path/$candidate" && ! -L "$install_path/$candidate" ]] || continue
                final_name="$candidate"; break
            done
        fi
        [[ -n "$final_name" ]] || { ui_error "目标命令冲突"; return 1; }
    fi
    target="$install_path/$final_name"
    _safe_target "$target" || { ui_error "不安全的安装目标"; return 1; }
    src=$(readlink -f "${BASH_SOURCE[0]}") || return 1
    [[ -f "$src" ]] || return 1
    bash -n "$src" || return 1
    if [[ -f "$target" ]] && cmp -s -- "$src" "$target"; then
        ui_success "已安装相同内容: $target"; return 0
    fi
    ui_info "安装目标: $target（仅更新管理工具）"
    ui_confirm "确认安装/升级?" "n" || return 0
    if [[ -e "$target" ]]; then
        version=$(_get_self_version "$target" || true)
        backup=$(mktemp "$target.v${version:-old}.XXXXXXXX") || return 1
        if ! cp -p -- "$target" "$backup"; then rm -f -- "$backup"; ui_error "备份失败"; return 1; fi
        ui_info "原文件备份: $backup"
    fi
    tmp=$(mktemp "$install_path/.svm-install.XXXXXXXX") || return 1
    if ! install -m 0755 -- "$src" "$tmp" || ! mv -fT -- "$tmp" "$target"; then
        rm -f -- "$tmp"; ui_error "安装失败"; return 1
    fi
    ui_success "安装完成: $target"

    # PATH 检查
    case ":$PATH:" in
        *":$install_path:"*) ;;
        *) ui_warn "注意: $install_path 不在 PATH 中，请手动加入" ;;
    esac

    # 验证
    if command -v "$final_name" >/dev/null 2>&1; then
        ui_info "验证: $(command -v "$final_name")"
        ui_info "现在可以直接输入 '$final_name' 启动"
    else
        ui_warn "命令未在 PATH 中找到，需重新登录或 source ~/.bashrc"
    fi

    # 升级/安装后的完整性检查：supervisord 与其开机自启状态
    echo
    ui_info "── 环境检查 ──"
    if has_supervisord; then
        ui_info "supervisord 已安装: $(supervisord --version 2>/dev/null | head -1)"
        if supervisor_alive; then
            ui_info "supervisord 运行中"
        else
            ui_warn "supervisord 未运行，运行 '$final_name' 进菜单 [2] 启动"
        fi
        # systemd 开机自启检查（不适用于非 systemd 环境）
        if [[ -d /run/systemd/system ]]; then
            local svc
            for svc in supervisor supervisord; do
                if systemctl cat "$svc" >/dev/null 2>&1; then
                    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
                        ui_info "开机自启 ($svc): 已启用"
                    else
                        ui_warn "开机自启 ($svc): 未启用，运行 '$final_name' 进菜单 [2] 配置"
                    fi
                    break
                fi
            done
        fi
    else
        ui_warn "supervisord 未安装，运行 '$final_name' 进菜单 [1] 安装"
    fi

    # 提示典型用法
    cat <<EOF

${C_GRAY}── 常用入口 ──${C_RESET}
  $final_name              # 进入交互菜单
  $final_name --install    # 安装/升级本命令（带 --as/--path）
  $final_name -c status    # 一次性命令：直接显示状态

EOF
}

# ============================================================================
#  用法 / 帮助
# ============================================================================

self_uninstall() (
    require_root || return 1
    local target="${1:-$(readlink -f "${BASH_SOURCE[0]}")}"
    [[ $# -le 1 && "$target" == /* ]] || { ui_error "用法: svm --uninstall [绝对安装路径]"; return 1; }
    _safe_target "$target" && _is_self_cmd "$target" || { ui_error "拒绝删除非本工具文件"; return 1; }
    ui_confirm "仅卸载 $target（保留 Supervisor、配置、备份、运行进程）?" "n" || return 0
    rm -- "$target" || return 1
    ui_success "管理工具已卸载"
)
usage() {
    cat <<EOF
${C_BOLD}Supervisor Manager v$SM_VERSION${C_RESET}

用法:
  sm.sh                       进入交互式菜单
  sm.sh --install [选项]      安装/升级为系统命令（默认 svm，冲突则降级 svmgr）
  svm --uninstall [绝对路径]  仅卸载管理工具
  sm.sh -c <cmd>              一次性命令
  sm.sh --help                显示本帮助

--install 选项:
  --as NAME                   指定命令名（默认 svm）
  --path PATH                 安装目录（默认 /usr/local/bin）
  --force                     跳过冲突检测

升级说明:
  用新版脚本重新执行 --install 即可升级；旧版本自动备份为带版本号和随机后缀的文件
  覆盖安装只更新本命令，不影响 /etc/supervisor 配置、systemd unit 与运行中的进程

-c 支持的命令:
  status                      supervisorctl status
  install                     调用菜单 [1]
  boot                        调用菜单 [2]

环境变量:
  SM_CONF_DIR                 子进程配置目录（默认 /etc/supervisor/conf.d）
  SM_MAIN_CONF                主配置文件
  SM_LOG_DIR                  日志目录
  SM_BACKUP_DIR               编辑/删除前的自动备份目录
  SM_NO_CLEAR=1               禁用首页清屏（保留终端滚动历史）
  SM_LOCALE=0                 关闭 locale 自适应；SM_LOCALE=<name> 指定 UTF-8 locale
  SM_WIDTH=68                 界面总宽（列数）
EOF
}

# ============================================================================
#  入口
# ============================================================================

# 显示宽度计算的字节表 + 自检（纯内建命令，开销可忽略；对所有模式生效）
_sm_bytes_init
_sm_width_selftest || true
_fit_width

# locale 自适应：在任何输出之前把本进程切到 UTF-8
# source 模式（SM_NO_ENTRY=1）跳过——改调用方的全局环境不是被加载者该做的事
if [[ "${SM_NO_ENTRY:-0}" != "1" ]]; then
    _ensure_utf8_locale
    _discover_main_conf || true
fi

# 解析参数（source 模式下 $# 是调用方的参数，不能当成自己的命令行来解析）
if [[ $# -ge 1 && "${SM_NO_ENTRY:-0}" != "1" ]]; then
    case "$1" in
        --help|-h)
            usage; exit 0 ;;
        --uninstall)
            shift; self_uninstall "$@"; exit $? ;;
        --install|install)
            shift
            self_install "$@"
            exit $?
            ;;
        -c)
            if [[ $# -lt 2 ]]; then
                ui_error "用法: sm.sh -c <command>"
                exit 1
            fi
            case "$2" in
                status)
                    if supervisor_alive; then
                        _svctl status
                    else
                        _report_not_alive
                        exit 1
                    fi
                    ;;
                install) action_install ;;
                boot)    action_boot ;;
                *) ui_error "未知命令: $2"; exit 1 ;;
            esac
            exit $?
            ;;
        --version|-V)
            echo "Supervisor Manager v$SM_VERSION"
            exit 0
            ;;
        *)
            ui_error "未知参数: $1"
            ui_info "执行 sm.sh --help 查看用法"
            exit 1
            ;;
    esac
fi

# 无参数：进入交互式菜单（SM_NO_ENTRY=1 时跳过，便于 source 加载）
if [[ "${SM_NO_ENTRY:-0}" != "1" ]]; then
    main_menu
fi