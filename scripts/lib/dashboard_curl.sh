# shellcheck shell=bash
# The curl transport for scripts/metrics_scrape_lib.sh: reaches a dashboard from the host and defines the
# two hooks that library asks for. Shared by every harness that logs in to a dashboard with curl
# (scripts/loadtest-ceiling.sh, scripts/validate-docker-build.sh, scripts/docker-regression-test.sh and
# the image smoke step of .github/workflows/ci.yml).
#
# Before calling anything here, set:
#
#   DASHBOARD_URL   the dashboard's base URL, such as http://127.0.0.1:4041
#   CURL            the curl to run (default curl)
#
# No secret ever reaches curl's argv, where `/proc/<pid>/cmdline` shows it to every local user while the
# request runs (#180). The login body goes on stdin through `--data-binary @-`, and the bearer header goes
# on stdin as a curl config line through `-K -`. Both are written by the shell's `printf` builtin, which
# runs no process of its own, so nothing is written to disk either.

# curl ARGS: the body on a 2xx, else one line saying what went wrong (the contract metrics_scrape_lib.sh
# states). The status comes on the last line of the output, so a body is never mistaken for it. stdin
# flows through to curl, which is how the callers below hand it the secret.
dashboard_request() {
  local curl="${CURL:-curl}"
  command -v "$curl" > /dev/null 2>&1 || { echo "curl not found"; return 1; }
  local response code
  response="$("$curl" -sS --max-time 5 -w '\n%{http_code}' "$@" 2> /dev/null)"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "curl could not reach $DASHBOARD_URL (exit $code)"
    return 1
  fi
  case "${response##*$'\n'}" in
    2??) printf '%s\n' "${response%$'\n'*}" ;;
    *) echo "HTTP ${response##*$'\n'}"; return 1 ;;
  esac
}

# POSTs JSON to PATH, the JSON on stdin.
ms_http_post() { # ms_http_post <path> <json>
  printf '%s' "$2" |
    dashboard_request -X POST -H 'Content-Type: application/json' --data-binary @- "$DASHBOARD_URL$1"
}

# GETs PATH as the session TOKEN, the Authorization header on stdin as a curl config line. The token is
# written unescaped: ms_login only hands out base64url tokens, which hold no quote, backslash or newline.
ms_http_get() { # ms_http_get <path> <token> [accept]
  printf 'header = "Authorization: Bearer %s"\n' "$2" |
    dashboard_request -K - -H "Accept: ${3:-text/plain}" "$DASHBOARD_URL$1"
}
