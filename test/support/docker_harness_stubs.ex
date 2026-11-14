defmodule Malachi.Test.DockerHarnessStubs do
  @moduledoc """
  Stubs for running the Docker validation harnesses (scripts/validate-docker-build.sh and
  scripts/docker-regression-test.sh) end to end without Docker or a node, so a test can check where the
  passwords and the session token travel (#180).

  Every stub records its argv in `argv.log`, one line per call; the curl stub records its stdin in
  `stdin.log`, NUL-terminated since a body may hold newlines; and the docker stub records, for each
  `run` (`docker compose ... run` too), the value every `-e` gives the container in `env.log`, resolving `-e NAME` from its own
  environment the way the docker client does. A secret is then asserted absent from `argv.log` and present
  where it belongs.

  An rpc answers STUB_RPC_REPLY (default: what the validation scripts look for), and `inspect` says the
  container is running.

  The curl stub answers like the dashboard: `/login` gives `{"token":"stub-token"}`, `/` a page, `/metrics`
  the JSON metrics, `/stream` a 200. STUB_CURL changes that: `login403`, `badtoken` (a token with a quote),
  or `stream401`.
  """

  @doc "Writes the stubs into `dir/stubs` and returns the paths a test reads back."
  def install!(dir) do
    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)

    for {name, body} <- [
          {"docker", docker()},
          {"curl", curl()},
          {"timeout", "#!/usr/bin/env bash\nshift\nexec \"$@\"\n"},
          {"sleep", "#!/usr/bin/env bash\nexit 0\n"},
          {"nc", "#!/usr/bin/env bash\nprintf 'nc %s\\n' \"$*\" >> \"$STUB_ARGV_LOG\"\nexit 0\n"}
        ] do
      path = Path.join(stubs, name)
      File.write!(path, body)
      File.chmod!(path, 0o755)
    end

    %{
      stubs: stubs,
      argv_log: Path.join(dir, "argv.log"),
      stdin_log: Path.join(dir, "stdin.log"),
      env_log: Path.join(dir, "env.log")
    }
  end

  @doc "The environment the stubs read, with `stubs` first on the PATH."
  def env(paths, extra \\ []) do
    base = [
      {"PATH", paths.stubs <> ":" <> System.get_env("PATH", "")},
      {"STUB_ARGV_LOG", paths.argv_log},
      {"STUB_STDIN_LOG", paths.stdin_log},
      {"STUB_ENV_LOG", paths.env_log},
      {"STUB_CURL", "ok"},
      {"CURL", nil},
      # Nothing the test runner exports may reach a container through `-e NAME`.
      {"MALACHI_ADMIN_PASS", nil},
      {"MALACHI_PRODUCER_PASS", nil},
      {"MALACHI_CONSUMER_PASS", nil},
      {"MALACHI_APP_PASS", nil},
      {"MALACHI_DEFAULT_USERS", nil}
    ]

    Enum.reduce(extra, base, fn {key, value}, acc -> List.keystore(acc, key, 0, {key, value}) end)
  end

  @doc "What `run` gave the containers, as a map of variable to value (the last value wins)."
  def container_env(paths) do
    for line <- String.split(File.read!(paths.env_log), "\n", trim: true), into: %{} do
      [key, value] = String.split(line, "=", parts: 2)
      {key, value}
    end
  end

  @doc "Every recorded argv, one call per line."
  def argv(paths), do: File.read!(paths.argv_log)

  @doc "What curl read on stdin, one entry per call."
  def curl_stdin(paths) do
    if File.exists?(paths.stdin_log), do: String.split(File.read!(paths.stdin_log), "\u0000", trim: true), else: []
  end

  defp docker do
    ~S"""
    #!/usr/bin/env bash
    printf 'docker %s\n' "$*" >> "$STUB_ARGV_LOG"
    # `docker run` and `docker compose ... run` alike: what each `-e` gives the container.
    case " $* " in
      *" run "*)
        prev=""
        for arg in "$@"; do
          if [ "$prev" = -e ]; then
            case "$arg" in
              *=*) echo "$arg" >> "$STUB_ENV_LOG" ;;
              *) echo "$arg=${!arg}" >> "$STUB_ENV_LOG" ;;
            esac
          fi
          prev="$arg"
        done ;;
    esac
    case "$1" in
      run)
        if [ "$2" = -d ]; then
          echo stub-container-id
        else
          # The image checks of validate-docker-build.sh: the runtime dependencies and the JIT.
          echo "All runtime dependencies present"
          echo "jit"
        fi ;;
      exec)
        case "$*" in
          *" rpc "*) printf '%b\n' "${STUB_RPC_REPLY:-PASS\nOK:produced=1\njit}" ;;
          *) echo 1 ;;
        esac ;;
      stats) echo "100MiB / 1GiB" ;;
      inspect) echo true ;;
      stop | rm | logs | restart | ps | compose) : ;;
      *) echo "stub docker: unexpected $*" >&2; exit 97 ;;
    esac
    """
  end

  defp curl do
    ~S"""
    #!/usr/bin/env bash
    printf 'curl %s\n' "$*" >> "$STUB_ARGV_LOG"
    { cat; printf '\0'; } >> "$STUB_STDIN_LOG"
    url="" out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift ;;
        -X | -H | -K | -w | --max-time | --data-binary) shift ;;
        -*) ;;
        *) url="$1" ;;
      esac
      shift
    done
    path="/${url#http://*/}"
    status=200 body=""
    case "$STUB_CURL $path" in
      "login403 /login") status=403 body='{"error":"invalid"}' ;;
      "badtoken /login") body='{"token":"stub\"token"}' ;;
      *" /login") body='{"token":"stub-token"}' ;;
      "stream401 /stream") status=401 ;;
      *" /metrics") body='{"topics":[]}' ;;
      *" /") body='<html>dashboard</html>' ;;
    esac
    if [ -n "$out" ]; then printf '%s' "$status"; else printf '%s\n%s' "$body" "$status"; fi
    """
  end
end
