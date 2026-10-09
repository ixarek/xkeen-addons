#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:$PATH
umask 077
APP_DIR=/opt/share/zapret-gui
CONFIG_DIR=/opt/etc/zapret-gui
PID_FILE=/opt/var/run/zapret-gui.pid
LOG_FILE=/tmp/zapret-gui-server.log
running() {
    [ -s "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE")
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fx "$APP_DIR/app.py" >/dev/null || return 1
    kill -0 "$pid" 2>/dev/null
}
start() {
    if running; then
        echo 'zapret-gui already running'; return 0
    fi
    rm -f "$PID_FILE"
    mkdir -p /opt/var/run /tmp/zapret-gui
    cd "$APP_DIR" || return 1
    # Bind/auth are read from settings.json; CLI flags would override changes in UI.
    nohup python3 "$APP_DIR/app.py" --config "$CONFIG_DIR" </dev/null >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE.new"
    mv -f "$PID_FILE.new" "$PID_FILE"
    sleep 2
    running
}
stop() {
    if running; then
        kill "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    return 0
}
case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) if running; then echo "zapret-gui running (PID $pid)"; else echo 'zapret-gui not running'; exit 1; fi ;;
    *) echo 'Usage: S99zapret-gui {start|stop|restart|status}'; exit 1 ;;
esac
