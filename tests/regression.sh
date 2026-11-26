#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bash -n sm.sh || exit 1
tmp=$(mktemp -d) || exit 1
trap 'supervisorctl -c "$SM_MAIN_CONF" shutdown >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
export SM_NO_ENTRY=1 SM_MAIN_CONF="$tmp/supervisord.conf" SM_BACKUP_DIR="$tmp/backups"
source ./sm.sh
set -e
mkdir -m 700 "$SM_BACKUP_DIR" "$tmp/conf.d"
cat > "$SM_MAIN_CONF" <<EOF
[unix_http_server]
file=$tmp/supervisor.sock
[supervisord]
logfile=$tmp/supervisord.log
pidfile=$tmp/supervisord.pid
childlogdir=$tmp
[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface
[supervisorctl]
serverurl=unix://$tmp/supervisor.sock
[include]
files=%(here)s/conf.d/app-*.conf
EOF
_discover_main_conf
_native_conf validate "$SM_MAIN_CONF"
[[ "$(_conf_include_patterns)" == "$tmp/conf.d/app-*.conf" ]]
[[ -z "$(_conf_source_files)" ]]
_preferred_conf_target test
[[ "$_SM_TARGET_FILE" == "$tmp/conf.d/app-test.conf" ]]
cat > "$_SM_TARGET_FILE" <<EOF
[program:original]
command=/bin/sleep 600
autostart=false
EOF
! _preferred_conf_target test
_program_exists original
! _program_exists test
backup=$(_backup_file "$tmp/conf.d/app-test.conf")
[[ "$(stat -c %a "$backup")" == 600 ]]
cmp "$backup" "$tmp/conf.d/app-test.conf"
ln -s "$tmp/conf.d/app-test.conf" "$tmp/conf.d/app-link.conf"
! _safe_target "$tmp/conf.d/app-link.conf"
rm "$tmp/conf.d/app-link.conf"
if ( _tx_begin "$tmp/conf.d/app-test.conf" &&
     printf '%s\n' '[program:broken]' > "$_TX_STAGE" &&
     _tx_publish &&
     _tx_apply ); then
    echo "invalid config unexpectedly accepted" >&2; exit 1
fi
cmp "$backup" "$tmp/conf.d/app-test.conf"
_native_conf validate "$SM_MAIN_CONF"
supervisord -c "$SM_MAIN_CONF"
_svctl pid
_check_daemon_identity
[[ -z "$(_reread_groups)" ]]
(
    _tx_begin "$tmp/conf.d/app-second.conf"
    printf '%s\n' '[program:second]' 'command=/bin/sleep 600' 'autostart=false' > "$_TX_STAGE"
    _tx_publish
    _tx_apply
)
[[ "$(_svctl status second 2>&1 || true)" == *STOPPED* ]]
(
    _tx_begin "$tmp/conf.d/app-second.conf"
    _TX_DIRTY=1
    rm "$_TX_TARGET"
    _tx_apply
)
[[ ! -e "$tmp/conf.d/app-second.conf" ]]
[[ "$(_svctl status original 2>&1 || true)" == *STOPPED* ]]
echo 'Supervisor Manager regression tests passed'

# Two isolated Supervisor daemons sharing package binaries.
conf_a="$SM_MAIN_CONF"
conf_b="$tmp/second.conf"
mkdir -m 700 "$tmp/second.d"
cat > "$conf_b" <<EOF
[unix_http_server]
file=$tmp/second.sock
[supervisord]
logfile=$tmp/second.log
pidfile=$tmp/second.pid
childlogdir=$tmp
[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface
[supervisorctl]
serverurl=unix://$tmp/second.sock
[include]
files=$tmp/second.d/*.conf
EOF
cat > "$tmp/second.d/other.conf" <<EOF
[program:other]
command=/bin/sleep 600
autostart=false
EOF
supervisord -c "$conf_b"
trap 'supervisorctl -c "$conf_a" shutdown >/dev/null 2>&1 || true; supervisorctl -c "$conf_b" shutdown >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
pid_a=$(supervisorctl -c "$conf_a" pid)
pid_b=$(supervisorctl -c "$conf_b" pid)
[[ "$pid_a" != "$pid_b" ]]
[[ "$(_svctl pid)" == "$pid_a" ]]
SM_MAIN_CONF="$conf_b"
_discover_main_conf
_check_daemon_identity
[[ "$(_svctl pid)" == "$pid_b" ]]
[[ "$(_svctl status other 2>&1 || true)" == *STOPPED* ]]
(
    _tx_begin "$tmp/second.d/new.conf" &&
    printf '%s\n' '[program:new]' 'command=/bin/sleep 600' 'autostart=false' > "$_TX_STAGE" &&
    _tx_publish && _tx_apply
)
[[ "$(supervisorctl -c "$conf_b" status new 2>&1 || true)" == *STOPPED* ]]
[[ "$(supervisorctl -c "$conf_a" status new 2>&1 || true)" != *STOPPED* ]]
[[ "$(supervisorctl -c "$conf_a" pid)" == "$pid_a" ]]
_SM_PROFILE_FILE="$tmp/profile/instance.conf"
_save_profile
[[ "$(stat -c %a "$_SM_PROFILE_FILE")" == 600 ]]
SM_MAIN_CONF="$conf_a"
_load_profile
[[ "$SM_MAIN_CONF" == "$conf_b" ]]
# Serial defaults to Chinese, with no ANSI escape bytes.
serial_help=$(env -u SM_LANG SM_NO_ENTRY=0 SM_SERIAL=1 SM_SERIAL_DELAY_MS=0 bash ./sm.sh --help)
[[ "$serial_help" == *"进入交互式菜单"* ]]
[[ "$serial_help" != *$'\033'* ]]
english_help=$(SM_LANG=en SM_NO_ENTRY=0 SM_SERIAL=1 SM_SERIAL_DELAY_MS=0 bash ./sm.sh --help)
[[ "$english_help" == *"Interactive menu"* ]]
[[ "$english_help" != *$'\033'* ]]
[[ "$(printf '%s' "$english_help" | LC_ALL=C tr -cd '\11\12\15\40-\176')" == "$english_help" ]]
# The default interface must be Chinese for both serial and SSH display paths.
printf '0\n' | env -u SM_LANG SM_NO_ENTRY=0 SM_SERIAL=1 SM_SERIAL_DELAY_MS=0 SM_MAIN_CONF="$conf_b" bash ./sm.sh > "$tmp/serial-zh.out"
grep -q '当前实例: 手动指定版本 (手动选择)' "$tmp/serial-zh.out"
grep -q '主程序:' "$tmp/serial-zh.out"
grep -q '控制程序:' "$tmp/serial-zh.out"
grep -q '主配置文件:' "$tmp/serial-zh.out"
grep -q '添加守护进程' "$tmp/serial-zh.out"
! grep -q $'\033' "$tmp/serial-zh.out"
printf '0\n' | env -u SM_LANG SM_NO_ENTRY=0 SM_SERIAL=0 SM_MAIN_CONF="$conf_b" bash ./sm.sh > "$tmp/normal-zh.out"
grep -q '当前实例: 手动指定版本 (手动选择)' "$tmp/normal-zh.out"
grep -q '主配置文件:' "$tmp/normal-zh.out"
mkdir -m 700 "$tmp/bin"
install -m 755 ./sm.sh "$tmp/bin/svm"
# Cancellation leaves the test copy installed; confirmation removes only it.
printf '13\nn\n0\n' | env -u SM_LANG SM_NO_ENTRY=0 SM_SERIAL=1 SM_SERIAL_DELAY_MS=0 SM_MAIN_CONF="$conf_b" bash "$tmp/bin/svm" > "$tmp/cancel.out"
[[ -f "$tmp/bin/svm" ]]
grep -q '卸载 SVM 管理工具' "$tmp/cancel.out"
printf '13\ny\n' | env SM_LANG=en SM_NO_ENTRY=0 SM_SERIAL=1 SM_SERIAL_DELAY_MS=0 SM_MAIN_CONF="$conf_b" bash "$tmp/bin/svm" > "$tmp/uninstall.out"
[[ ! -e "$tmp/bin/svm" ]]
grep -q 'Manager removed' "$tmp/uninstall.out"
[[ "$(supervisorctl -c "$conf_a" pid)" == "$pid_a" ]]
[[ "$(supervisorctl -c "$conf_b" pid)" == "$pid_b" ]]
[[ -f "$conf_a" && -f "$conf_b" && -d "$SM_BACKUP_DIR" ]]
echo 'Multi-instance, serial and uninstall regression tests passed'

# UI throttling: inspect exact output and delay calls using a stub, not wall-clock
# timing. Normal mode and delay=0 must not call sleep. Data-return functions
# must remain untouched.
(
    _SM_SERIAL=1
    _SM_SERIAL_DELAY_MS=50
    _SM_SERIAL_DELAY=0.050
    sleep() { printf '%s\n' "$1" >> "$tmp/ui-sleeps"; }
    : > "$tmp/ui-sleeps"
    _ui_printf '%s\n%s\n' '确认安装/升级' '主配置文件' > "$tmp/ui-paced"
    [[ "$(cat "$tmp/ui-paced")" == $'确认安装/升级\n主配置文件' ]]
    [[ "$(cat "$tmp/ui-sleeps")" == $'0.050\n0.050' ]]
    _ui_write '确认安装/升级? [y/N]: ' > "$tmp/ui-prompt"
    [[ "$(cat "$tmp/ui-prompt")" == '确认安装/升级? [y/N]: ' ]]
    [[ "$(wc -l < "$tmp/ui-sleeps")" -eq 3 ]]
    _SM_SERIAL=0
    _ui_print 'SSH output' >/dev/null
    [[ "$(wc -l < "$tmp/ui-sleeps")" -eq 3 ]]
    _SM_SERIAL=1
    _SM_SERIAL_DELAY_MS=0
    _ui_print 'No delay' >/dev/null
    [[ "$(wc -l < "$tmp/ui-sleeps")" -eq 3 ]]
)
echo 'Serial UI pacing regression tests passed'
