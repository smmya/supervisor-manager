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
