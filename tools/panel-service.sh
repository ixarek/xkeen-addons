#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:$PATH
umask 077
APP_DIR=/opt/share/zapret-gui
CONFIG_DIR=/opt/etc/zapret-gui
PID_FILE=/opt/var/run/zapret-gui.pid
LOG_FILE=/tmp/zapret-gui-server.log
start() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo 'zapret-gui already running'; return 0
    fi
    mkdir -p /opt/var/run /tmp/zapret-gui
    cd "$APP_DIR" || return 1
    # Bind/auth are read from settings.json; CLI flags would override changes in UI.
    nohup python3 app.py --config "$CONFIG_DIR" </dev/null >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}
stop() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    return 0
}
case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null ;;
    *) echo 'Usage: S99zapret-gui {start|stop|restart|status}'; exit 1 ;;
esac
