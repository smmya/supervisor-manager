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
# Forced serial help must be ASCII with no ANSI escape bytes.
serial_help=$(SM_NO_ENTRY=0 SM_SERIAL=1 bash ./sm.sh --help)
[[ "$serial_help" == *"Interactive menu"* ]]
[[ "$serial_help" != *$'\033'* ]]
[[ "$(printf '%s' "$serial_help" | LC_ALL=C tr -cd '\11\12\15\40-\176')" == "$serial_help" ]]
mkdir -m 700 "$tmp/bin"
install -m 755 ./sm.sh "$tmp/bin/svm"
# Cancellation leaves the test copy installed; confirmation removes only it.
printf '13\nn\n0\n' | env SM_NO_ENTRY=0 SM_SERIAL=1 SM_MAIN_CONF="$conf_b" bash "$tmp/bin/svm" > "$tmp/cancel.out"
[[ -f "$tmp/bin/svm" ]]
grep -q 'Uninstall SVM manager' "$tmp/cancel.out"
printf '13\ny\n' | env SM_NO_ENTRY=0 SM_SERIAL=1 SM_MAIN_CONF="$conf_b" bash "$tmp/bin/svm" > "$tmp/uninstall.out"
[[ ! -e "$tmp/bin/svm" ]]
grep -q 'Manager removed' "$tmp/uninstall.out"
[[ "$(supervisorctl -c "$conf_a" pid)" == "$pid_a" ]]
[[ "$(supervisorctl -c "$conf_b" pid)" == "$pid_b" ]]
[[ -f "$conf_a" && -f "$conf_b" && -d "$SM_BACKUP_DIR" ]]
echo 'Multi-instance, serial and uninstall regression tests passed'
