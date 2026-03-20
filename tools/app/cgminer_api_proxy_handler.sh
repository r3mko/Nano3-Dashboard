#!/bin/sh
# cgminer_api_proxy_handler.sh
# Single-request HTTP handler for inetd.
# Reads HTTP request headers/body from stdin, forwards JSON payload to cgminer API on 127.0.0.1:4028
# using telnet, then writes a JSON HTTP response to stdout.

CGMINER_HOST="${CGMINER_HOST:-127.0.0.1}"
CGMINER_PORT="${CGMINER_PORT:-4028}"
TELNET_WRITE_DELAY="${TELNET_WRITE_DELAY:-1}"

build_http_response() {
  status_line="$1"
  body="$2"
  length="$(printf '%s' "$body" | wc -c | tr -d ' ')"
  printf '%s\r\n' "$status_line"
  printf 'Content-Type: application/json\r\n'
  printf 'Access-Control-Allow-Origin: *\r\n'
  printf 'Access-Control-Allow-Methods: POST, OPTIONS\r\n'
  printf 'Access-Control-Allow-Headers: Content-Type\r\n'
  printf 'Connection: close\r\n'
  printf 'Content-Length: %s\r\n' "$length"
  printf '\r\n'
  printf '%s' "$body"
}

respond_error() {
  http_status="$1"
  error_code="$2"
  error_msg="$3"
  build_http_response "$http_status" "{\"STATUS\":[{\"STATUS\":\"E\",\"Code\":$error_code,\"Msg\":\"$error_msg\"}]}"
}

extract_json_string_field() {
  key="$1"
  json="$(printf '%s' "$2" | tr -d '\r\n')"
  printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

parse_ascset_parameter() {
  asc_param="$1"
  ASC_INDEX=""
  ASC_KEY=""
  ASC_VALUE=""

  # Expected format: "<asc_index>,<key>,<value>"
  IFS=, read -r ASC_INDEX ASC_KEY ASC_VALUE ASC_EXTRA <<EOF
$asc_param
EOF

  [ -n "$ASC_INDEX" ] || return 1
  [ -n "$ASC_KEY" ] || return 1
  [ -n "$ASC_VALUE" ] || return 1
  [ -z "$ASC_EXTRA" ] || return 1
  case "$ASC_INDEX" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  return 0
}

validate_fan_spd_value() {
  value="$1"
  if [ "$value" = "-1" ]; then
    return 0
  fi
  case "$value" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  # Backend accepts 0-100 and -1 (auto).
  [ "$value" -ge 0 ] && [ "$value" -le 100 ]
}

is_allowed_ascset_parameter() {
  param="$1"
  parse_ascset_parameter "$param" || return 1
  case "$ASC_KEY" in
    fan-spd)
      validate_fan_spd_value "$ASC_VALUE"
      ;;
    *)
      # Add future ascset keys here.
      return 1
      ;;
  esac
}

is_command_allowed() {
  payload="$1"
  cmd="$(extract_json_string_field "command" "$payload")"
  param="$(extract_json_string_field "parameter" "$payload")"

  [ -n "$cmd" ] || return 1

  case "$cmd" in
    ascset)
      is_allowed_ascset_parameter "$param"
      ;;
    *)
      # Add future command handlers here.
      return 1
      ;;
  esac
}

run_cgminer_query() {
  payload="$1"
  command -v telnet >/dev/null 2>&1 || return 127

  (
    printf '%s\n' "$payload"
    sleep "$TELNET_WRITE_DELAY"
  ) | telnet "$CGMINER_HOST" "$CGMINER_PORT" 2>/dev/null
}

content_length=0
first_line=""
method=""

IFS= read -r first_line || {
  respond_error "HTTP/1.1 400 Bad Request" 400 "Missing request line"
  exit 0
}
first_line="$(printf '%s' "$first_line" | tr -d '\r')"

case "$first_line" in
  OPTIONS\ *) method="OPTIONS" ;;
  POST\ *)
    method="POST"
    ;;
  *)
    method="OTHER"
    ;;
esac

while IFS= read -r line; do
  line="$(printf '%s' "$line" | tr -d '\r')"
  [ -z "$line" ] && break
  case "$line" in
    [Cc]ontent-[Ll]ength:*)
      content_length="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
      ;;
  esac
done

case "$content_length" in
  ''|*[!0-9]*)
    content_length=0
    ;;
esac

# Always consume possible request body before replying to avoid TCP reset on close.
if [ "$content_length" -gt 0 ]; then
  if [ "$method" = "POST" ]; then
    body="$(dd bs=1 count="$content_length" 2>/dev/null)"
  else
    dd bs=1 count="$content_length" >/dev/null 2>&1
    body=""
  fi
else
  body=""
fi

if [ "$method" = "OPTIONS" ]; then
  build_http_response "HTTP/1.1 204 No Content" ""
  exit 0
fi

if [ "$method" != "POST" ]; then
  respond_error "HTTP/1.1 405 Method Not Allowed" 405 "Only POST is supported"
  exit 0
fi

if [ "$content_length" -le 0 ]; then
  respond_error "HTTP/1.1 400 Bad Request" 400 "Missing or invalid Content-Length"
  exit 0
fi

if [ -z "$body" ]; then
  respond_error "HTTP/1.1 400 Bad Request" 400 "Missing JSON body"
  exit 0
fi

if ! is_command_allowed "$body"; then
  respond_error "HTTP/1.1 403 Forbidden" 403 "Command blocked by proxy allowlist"
  exit 0
fi

cgminer_out="$(run_cgminer_query "$body")"
cgminer_rc=$?
cgminer_resp="$(printf '%s' "$cgminer_out" | tr -d '\r\000' | grep -m1 -o '{.*}')"
if [ -z "$cgminer_resp" ]; then
  if [ "$cgminer_rc" -eq 127 ]; then
    respond_error "HTTP/1.1 500 Internal Server Error" 500 "cgminer proxy error: telnet command unavailable"
  else
    respond_error "HTTP/1.1 502 Bad Gateway" 502 "cgminer proxy error: empty response from 4028"
  fi
  exit 0
fi

build_http_response "HTTP/1.1 200 OK" "$cgminer_resp"
