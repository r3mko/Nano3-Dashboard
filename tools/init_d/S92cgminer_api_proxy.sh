#!/bin/sh
# S92cgminer_api_proxy
# init script for cgminer API HTTP proxy (4029 -> cgminer 4028).

DAEMON="cgminer_api_proxy"
PIDFILE="/var/run/${DAEMON}.pid"
DEFER_PIDFILE="/var/run/${DAEMON}.deferred.pid"
LISTEN_PORT="${LISTEN_PORT:-4029}"
HANDLER_PATH="${HANDLER_PATH:-/mnt/heater/app/cgminer_api_proxy_handler.sh}"
INETD_CONF="${INETD_CONF:-/tmp/cgminer_api_proxy_inetd.conf}"
LOGFILE="/tmp/${DAEMON}.log"
DEFER_WAIT_MAX="${DEFER_WAIT_MAX:-120}"
DEFER_INTERVAL="${DEFER_INTERVAL:-3}"

write_inetd_conf() {
  cat >"$INETD_CONF" <<EOF
$LISTEN_PORT stream tcp nowait root $HANDLER_PATH cgminer_api_proxy_handler.sh
EOF
}

is_running() {
  if [ ! -r "$PIDFILE" ]; then
    return 1
  fi
  read pid < "$PIDFILE"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_inetd_now() {
  write_inetd_conf || {
    echo "ERROR (failed to write $INETD_CONF)"
    return 1
  }

  start-stop-daemon -S -q -b -m -p "$PIDFILE" -x "$(command -v inetd)" -- -f "$INETD_CONF" >>"$LOGFILE" 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "ERROR"
    return "$status"
  fi

  sleep 1
  if is_running; then
    echo "OK"
    return 0
  fi
  echo "ERROR (exited after start; check $LOGFILE)"
  return 1
}

schedule_deferred_start() {
  if [ -r "$DEFER_PIDFILE" ]; then
    read dpid < "$DEFER_PIDFILE"
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
      echo "DEFERRED (already waiting for handler)"
      return 0
    fi
  fi

  (
    waited=0
    while [ "$waited" -lt "$DEFER_WAIT_MAX" ]; do
      if [ -x "$HANDLER_PATH" ] && command -v inetd >/dev/null 2>&1; then
        if ! is_running; then
          if write_inetd_conf >/dev/null 2>&1; then
            start-stop-daemon -S -q -b -m -p "$PIDFILE" -x "$(command -v inetd)" -- -f "$INETD_CONF" >>"$LOGFILE" 2>&1
            sleep 1
            if ! is_running; then
              echo "$(date) deferred start failed to stay running; check $LOGFILE" >>"$LOGFILE"
            fi
          else
            echo "$(date) deferred start could not write $INETD_CONF" >>"$LOGFILE"
          fi
        fi
        rm -f "$DEFER_PIDFILE"
        exit 0
      fi
      sleep "$DEFER_INTERVAL"
      waited=$((waited + DEFER_INTERVAL))
    done
    echo "$(date) timeout waiting for handler: $HANDLER_PATH" >>"$LOGFILE"
    rm -f "$DEFER_PIDFILE"
  ) &
  echo "$!" > "$DEFER_PIDFILE"
  echo "DEFERRED (waiting for handler path)"
  return 0
}

start() {
  echo -n "Starting $DAEMON... "

  if is_running; then
    echo "OK (already running)"
    return 0
  fi

  if ! command -v inetd >/dev/null 2>&1; then
    echo "ERROR (inetd not found)"
    return 1
  fi

  if [ ! -x "$HANDLER_PATH" ]; then
    schedule_deferred_start
    return $?
  fi

  start_inetd_now
}

stop() {
  echo -n "Stopping $DAEMON... "

  if [ -r "$DEFER_PIDFILE" ]; then
    read dpid < "$DEFER_PIDFILE"
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
      kill "$dpid" >/dev/null 2>&1
    fi
    rm -f "$DEFER_PIDFILE"
  fi

  start-stop-daemon -K -q -p "$PIDFILE" >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 0 ] || [ "$status" -eq 1 ]; then
    rm -f "$PIDFILE"
    rm -f "$INETD_CONF"
    echo "OK"
    return 0
  else
    echo "ERROR"
    return "$status"
  fi
}

restart() {
  stop
  start
}

case "$1" in
  start|stop|restart)
    "$1"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac

exit $?
