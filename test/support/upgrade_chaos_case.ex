defmodule Malachi.Test.UpgradeChaosCase do
  @moduledoc """
  The case template of the tests of scripts/docker-upgrade-chaos.sh (issue #196), split across modules so the
  partitions of the suite share them out (#390). It decides which release is OLD, which tree each image is built
  from, which image and machine version pin each node runs at each step, and what counts as a refused rollback.
  None of that needs a cluster, and a real run takes about half an hour.

  The drill runs for real in a throwaway git repository with release tags, so the OLD ref is resolved, exported and
  patched by git itself; `docker` is a stub first on the PATH that logs every call and answers from STUB_*
  variables, and `sleep` returns at once. Every test has its own repository, stubs, log and result file under its
  tmp_dir, and the drill gets its environment per call, so the modules run async.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  using do
    quote do
      import Malachi.Test.UpgradeChaosCase

      @moduletag :tmp_dir
      @moduletag timeout: 300_000
    end
  end

  @scripts Path.expand("../../scripts", __DIR__)

  # A test run by a git hook inherits these, and any one of them would point git at the host repository
  # instead of the throwaway one (the same set test/scripts/worktree_env_test.exs clears).
  # A tar that stops reading early, as bsdtar does at the end-of-archive marker, every time it extracts from
  # stdin: short groups (-xf -, -x -f -, -xC dir), an attached operand (-xfFILE), long options (--extract,
  # --get, --file -, --file=-) and the dashless old style (tar xf -) are all told apart from extracting a
  # named archive, which, like anything else, goes to the real tar (REAL_TAR, filled in by the test).
  @early_tar ~S"""
  #!/usr/bin/env bash
  extract=0; archive=""; want_archive=0; first=1
  for arg in "$@"; do
    if [ "$want_archive" = 1 ]; then archive="$arg"; want_archive=0; first=0; continue; fi
    case "$arg" in
      --extract|--get) extract=1 ;;
      --file=*) archive="${arg#--file=}" ;;
      --file) want_archive=1 ;;
      --*) ;;
      -*)
        group="${arg#-}"
        case "$group" in *x*) extract=1 ;; esac
        case "$group" in
          *f) want_archive=1 ;;
          *f*) archive="${group#*f}" ;;
        esac
        ;;
      *)
        if [ "$first" = 1 ]; then
          case "$arg" in *x*) extract=1 ;; esac
          case "$arg" in *f*) want_archive=1 ;; esac
        fi
        ;;
    esac
    first=0
  done
  if [ "$extract" = 1 ] && { [ -z "$archive" ] || [ "$archive" = "-" ]; }; then
    head -c 512 > /dev/null
    exit 0
  fi
  exec "REAL_TAR" "$@"
  """

  @no_git_env [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}, {"GIT_COMMON_DIR", nil}, {"GIT_INDEX_FILE", nil}]

  @doc "The repository's scripts directory, where the drill and its library live."
  def scripts_dir, do: @scripts

  @doc "A tar stub that stops reading stdin at the end-of-archive marker, as bsdtar does; REAL_TAR is the real one."
  def early_tar, do: @early_tar

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    for tool <- ~w(bash jq awk sed tar git uptime) do
      System.find_executable(tool) || flunk("#{tool} is required to test scripts/docker-upgrade-chaos.sh")
    end

    :ok
  end

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(root, "scripts"))

    for name <- ~w(docker-upgrade-chaos.sh chaos_lib.sh) do
      File.cp!(Path.join(@scripts, name), Path.join([root, "scripts", name]))
    end

    write!(root, "benchmark/Dockerfile.loadtest", "FROM scratch\n")
    write!(root, "lib/malachi/cluster/machine_version.ex", "defmodule M do\n  @code_version 3\nend\n")
    write!(root, "lib/canary.txt", "released\n")
    # Every release here serves the stream keys; a test that needs one that does not cuts it itself.
    write!(root, "lib/malachi/tcp_protocol.ex", "defmodule T do\n  # api_key == Wire.fetch_range_key() ->\nend\n")
    write!(root, ".gitignore", "/tmp/\n")
    write!(root, "test/support/canary.patch", patch("lib/canary.txt", "released", "canary") <> version_patch(4))

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "drill@example.com"])
    git!(root, ["config", "user.name", "drill"])
    git!(root, ["config", "commit.gpgsign", "false"])
    write!(root, "mix.exs", ~s(defmodule P do\n  @version "0.13.0"\nend\n))
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "one"])
    git!(root, ["tag", "v0.13.0"])
    write!(root, "mix.exs", ~s(defmodule P do\n  @version "0.16.2"\nend\n))
    write!(root, "lib/feature.txt", "0.16.2\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "release 0.16.2"])
    git!(root, ["tag", "v0.16.2"])
    write!(root, "mix.exs", ~s(defmodule P do\n  @version "0.16.4"\nend\n))
    write!(root, "lib/feature.txt", "0.16.4\n")
    # From 0.16.4 on (in this repository) a node resumes its vnode members after a restart (#136).
    write!(root, "lib/malachi/application.ex", "defmodule A do\n  def resume_local_vnodes(_v), do: []\nend\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-am", "two"])
    git!(root, ["tag", "v0.16.4"])
    # The tree is ahead of the newest release: its code differs from v0.16.4's.
    write!(root, "mix.exs", ~s(defmodule P do\n  @version "0.17.0"\nend\n))
    write!(root, "lib/feature.txt", "unreleased\n")
    git!(root, ["commit", "-q", "-am", "three"])

    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)
    write!(stubs, "docker", docker_stub())
    File.chmod!(Path.join(stubs, "docker"), 0o755)
    # Time passing is acks arriving: a checker keeps producing while the drill waits.
    write!(stubs, "sleep", ~S"""
    #!/usr/bin/env bash
    f="$STUB_LOG.acked"
    [ -f "$f" ] && [ -f "$(cat "$f")" ] && [ ! -f "$STUB_LOG.stalled" ] && echo more >> "$(cat "$f")"
    exit 0
    """)

    File.chmod!(Path.join(stubs, "sleep"), 0o755)

    %{
      root: root,
      stubs: stubs,
      log: Path.join(dir, "docker.log"),
      work_root: Path.join(dir, "chaos"),
      result: Path.join(dir, "result.json")
    }
  end

  def run_drill(ctx, env \\ []) do
    base = [
      {"PATH", "#{ctx.stubs}:#{System.get_env("PATH")}"},
      {"STUB_LOG", ctx.log},
      {"CHAOS_WORK_ROOT", ctx.work_root},
      {"CHAOS_RESULT_FILE", ctx.result},
      {"UPGRADE_CANARY_PATCH", "test/support/canary.patch"},
      # Nothing from the environment running the tests may leak into the drill.
      {"OLD_REF", nil},
      {"OLD_PATCH", nil},
      {"NEW_PATCH", nil},
      {"PHASE1_WINDOW_S", nil},
      {"PHASE2_WINDOW_S", nil},
      {"PHASE3_WINDOW_S", nil},
      {"PROGRESS_TIMEOUT_S", nil},
      {"COMPOSE_PROJECT_NAME", nil},
      {"MALACHI_RA_MACHINE_VERSION", nil},
      {"MALACHI_SEGMENT_PREALLOC_BYTES", nil},
      {"UPGRADE_IMAGE_1", nil},
      {"UPGRADE_IMAGE_2", nil},
      {"UPGRADE_IMAGE_3", nil},
      {"UPGRADE_RESTART_3", nil},
      {"CHAOS_CERTIFICATION", nil}
      | @no_git_env
    ]

    env = Enum.reduce(env, base, fn {key, value}, acc -> List.keystore(acc, key, 0, {key, value}) end)
    script = Path.join([ctx.root, "scripts", "docker-upgrade-chaos.sh"])
    System.cmd(System.find_executable("bash"), [script], env: env, stderr_to_stdout: true)
  end

  def docker_calls(ctx) do
    if File.exists?(ctx.log), do: String.split(File.read!(ctx.log), "\n", trim: true), else: []
  end

  def result(ctx), do: ctx.result |> File.read!() |> Jason.decode!()

  def write!(root, path, body) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  def git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true, env: @no_git_env)
    output
  end

  # Raises NEW's machine version the way the real canary patch does, which is where the drill reads it.
  def version_patch(version) do
    """
    diff --git a/lib/malachi/cluster/machine_version.ex b/lib/malachi/cluster/machine_version.ex
    --- a/lib/malachi/cluster/machine_version.ex
    +++ b/lib/malachi/cluster/machine_version.ex
    @@ -1,3 +1,3 @@
     defmodule M do
    -  @code_version 3
    +  @code_version #{version}
     end
    """
  end

  def patch(path, from, to) do
    """
    diff --git a/#{path} b/#{path}
    --- a/#{path}
    +++ b/#{path}
    @@ -1 +1 @@
    -#{from}
    +#{to}
    """
  end

  # Answers from these variables:
  #   STUB_RUNNING        names `docker ps` lists as running
  #   STUB_MIXED_FLAG     accepted: the flag is switched on while OLD nodes remain
  #   STUB_MIXED_CANARY   applied: the canary command applies at the pinned version;
  #                       old_leader: an OLD leader, which does not know it, refuses it
  #   STUB_UNKNOWN_CASTS  what an OLD node's /metrics counts (default 7)
  #   STUB_CONTROL_PLANE  diverged: the checker's control-plane mode reports a divergence
  #   STUB_EFFECTIVE      the effective machine version after the pin is removed (default 4); also the
  #                       version the phase 1 refusal names the canary as introduced at, so a test that
  #                       raises NEW's version in its patch sets this to the same number
  #   STUB_FORMAT         the format the markers report after the flip (default 3)
  #   STUB_REFUSAL        healthy: OLD starts on the directory; flag: it exits 78 for the flag, not the marker
  #   STUB_MD5_CHANGES    1: the data directory's digest differs after the refused start
  #   STUB_CRASH          1: node 2's first log (its OLD container, replaced in phase 1) carries a crash report
  #                       over an unknown message; old_timeout / new_timeout: node 2's first log from that
  #                       build carries the heal coordinator's :metadata call timing out; old_keyerror: node 2's
  #                       first OLD log carries a KeyError, a known tag in a shape it cannot read;
  #                       old_apply_heal_timeout: node 2's first OLD log carries the heal coordinator's
  #                       {:apply_heal, ...} call timing out
  #   STUB_CACHE_NOTE     what node 3's broker cache holds as the canary note (default nil)
  #   STUB_BUILD_FAILS    old or new: that image does not build
  #   STUB_SPLIT          refused: the reshard is refused
  #   STUB_STALL_ON_SPLIT 1: no ack arrives once the split has run
  #   STUB_STALL_ON_REFUSED_ROLLBACK 1: no ack arrives once node 3 stops for the refused rollback
  #   STUB_RING_AFTER_ROLLBACK  the vnode count every ring read after the first reports
  #   STUB_UP_REFUSED_NODE      fail: compose cannot start node 3 on OLD after the flip
  #   STUB_PRODUCE_FAILS_ON     a host list: a load test through exactly those hosts reports errors
  #   STUB_FINAL_CANARY   refused: the canary command is refused once the pin is removed
  #   STUB_FINAL_FLAG     refused: the flag is refused with every node on NEW
  #
  # Every call after the checker starts appends an ack to its file, the way a producing checker would.
  defp docker_stub do
    ~S"""
    #!/usr/bin/env bash
    full="$*"
    args="$*"
    if [ "$1" = compose ]; then
      shift
      while [ "$1" = -f ]; do shift 2; done
      args="$*"
    fi
    # Compose reads the whole override, and it requires an image for every node.
    if [[ "$full" == *docker-compose.upgrade.yml* ]] && [ -z "${UPGRADE_IMAGE_1:-}" ]; then
      echo "compose: required variable UPGRADE_IMAGE_1 is missing a value" | tee -a "$STUB_LOG"
      exit 1
    fi
    case "$1" in
      up)
        img() { v="$1"; echo "${v##*:}"; }
        # Remember what each recreated node runs, so `inspect` answers with it as docker does.
        for n in 1 2 3; do
          case " $* " in *" malachi$n "*) v="UPGRADE_IMAGE_$n"; echo "${!v:-}" > "$STUB_LOG.image.$n" ;; esac
        done
        args="$args | pin=${MALACHI_RA_MACHINE_VERSION:-} images=$(img "$UPGRADE_IMAGE_1"),$(img "$UPGRADE_IMAGE_2"),$(img "$UPGRADE_IMAGE_3") restart=${UPGRADE_RESTART_3:-}" ;;
      build)
        ctx="${@: -1}"
        [ -n "${STUB_BUILD_FAILS:-}" ] && [ "$(basename "$ctx")" = "ctx-${STUB_BUILD_FAILS}" ] && {
          echo "build ctx=$(basename "$ctx") failed" >> "$STUB_LOG"
          exit 1
        }
        [ -n "$ctx" ] && [ -d "$ctx" ] &&
          args="$args ctx=$(basename "$ctx") canary=$(cat "$ctx/lib/canary.txt") version=$(sed -n 's/.*"\(.*\)".*/\1/p' "$ctx/mix.exs")" ;;
    esac
    echo "${args//$'\n'/ }" >> "$STUB_LOG"
    if [ "$1" = up ] && [ "${STUB_UP_REFUSED_NODE:-}" = fail ] && [ "${UPGRADE_RESTART_3:-}" = on-failure:3 ]; then
      exit 1
    fi

    # The split is the moment acks stop, when asked: before this very call counts as one.
    [[ "$full" == *malachi.reshard* ]] && [ "${STUB_STALL_ON_SPLIT:-}" = 1 ] && touch "$STUB_LOG.stalled"
    # The refused rollback is the one step that reads node 3's log BEFORE stopping it (a roll stops first),
    # so a stop of malachi3 right after that read is where its acks stop, when asked.
    if [ "${STUB_STALL_ON_REFUSED_ROLLBACK:-}" = 1 ] && [ -f "$STUB_LOG.logs3" ] && [[ "$full" == *" stop malachi3"* ]]; then
      touch "$STUB_LOG.stalled"
    fi
    rm -f "$STUB_LOG.logs3"
    [[ "$full" == "logs malachi-cluster-3"* ]] && touch "$STUB_LOG.logs3"
    acked_file="$STUB_LOG.acked"
    [ -f "$acked_file" ] && [ -f "$(cat "$acked_file")" ] && [ ! -f "$STUB_LOG.stalled" ] && echo more >> "$(cat "$acked_file")"

    case "$1" in
      ps)
        case "$*" in
          *health=healthy*) printf 'malachi-cluster-1\nmalachi-cluster-2\nmalachi-cluster-3\n' ;;
          *) [ -n "${STUB_RUNNING:-}" ] && printf '%s\n' "$STUB_RUNNING" ;;
        esac ;;
      inspect)
        case "$*" in
          *Mounts*) echo "vol-${2##*-}" ;;
          *Config.Image*) cat "$STUB_LOG.image.${2##*-}" 2>/dev/null || echo "repo-malachi${2##*-}" ;;
          *NetworkSettings*) echo stub-net ;;
          *State.Status*)
            case "${STUB_REFUSAL:-}" in
              healthy) echo "running 0 healthy" ;;
              *) echo "exited 78 " ;;
            esac ;;
        esac ;;
      exec)
        case "$*" in
          *"malachi.flag enable producer_streams"*) echo "cluster flag enabled: producer_streams" ;;
          *"malachi.flag enable"*)
            if [ "$2" = malachi-cluster-3 ] && [ "${STUB_MIXED_FLAG:-}" != accepted ]; then
              echo "these nodes are not alive or do not support that flag: malachi@malachi1, malachi@malachi2. Upgrade them"
              exit 1
            fi
            [ "${STUB_FINAL_FLAG:-}" = refused ] && { echo "the flag store did not answer in time"; exit 1; }
            echo "cluster flag enabled: upgrade_canary" ;;
          *"malachi.ring --show"*)
            n=$(( $(cat "$STUB_LOG.ring" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$STUB_LOG.ring"
            count=5
            [ "$n" -gt 1 ] && [ -n "${STUB_RING_AFTER_ROLLBACK:-}" ] && count=$STUB_RING_AFTER_ROLLBACK
            echo "durable ring: version 3, $count vnodes (ring size 1024)" ;;
          *malachi.reshard*)
            [ "${STUB_SPLIT:-}" = refused ] && { echo "reshard refused: the ring is busy"; exit 1; }
            echo "resharded" ;;
          *canary_note*)
            if [ "$2" = malachi-cluster-3 ]; then
              case "${STUB_MIXED_CANARY:-}" in
                applied) reply=":ok" ;;
                old_leader) reply="{:error, {:unknown_command, {:canary_note, 3}, 3}}" ;;
                *) reply="{:error, {:unsupported_command, {:canary_note, 3}, ${STUB_EFFECTIVE:-4}, 3}}" ;;
              esac
            elif [ "${STUB_FINAL_CANARY:-}" = refused ]; then
              reply="{:error, {:unsupported_command, {:canary_note, 3}, ${STUB_EFFECTIVE:-4}, 3}}"
            else
              reply=":ok"
            fi
            # Read in the same VM as the command: the reply, then what the broker's cache holds right after.
            if [[ "$*" == *":sys, :get_state"* ]]; then
              echo "reply: $reply"
              echo "canary_note: ${STUB_CACHE_NOTE:-nil}"
            else
              echo "$reply"
            fi ;;
          # The control plane follows the pin while there is one, as ra does once every member runs the version.
          *effective_machine_version*) echo "%{effective_machine_version: ${STUB_STUCK_VERSION:-${MALACHI_RA_MACHINE_VERSION:-${STUB_EFFECTIVE:-4}}}}" ;;
          *"sh -s"*)
            cat >/dev/null
            # Only an OLD node counts the canary cast as unknown; NEW node 3 understands it.
            count=0
            [ "$3" = malachi-cluster-1 ] && count=${STUB_UNKNOWN_CASTS:-7}
            echo "malachi_unexpected_messages_total{server=\"replication\",kind=\"cast\"} $count" ;;
          *malachi.format*) printf 'format=%s\nwritten_by=x\nrequires=x\n' "${STUB_FORMAT:-3}" ;;
        esac ;;
      logs)
        echo "log line of $2"
        if [ "$2" = malachi-cluster-3 ]; then
          case "${STUB_REFUSAL:-}" in
            flag) echo "REFUSING TO START (exit 78): the cluster flag upgrade_canary is on" ;;
            *) echo "REFUSING TO START (exit 78): the format marker /data/malachi_log/malachi.format records format 3, written by release x" ;;
          esac
        fi
        if [ "${STUB_CRASH:-}" = 1 ] && [ "$2" = malachi-cluster-2 ] && [ ! -f "$STUB_LOG.crashed" ]; then
          touch "$STUB_LOG.crashed"
          echo "** (FunctionClauseError) no function clause matching in Malachi.Cluster.ReplicationServer.handle_cast/2"
        fi
        # A crash that is not over an unknown message, in a log of the build named by STUB_CRASH (old or new).
        running=$(cat "$STUB_LOG.image.${2##*-}" 2>/dev/null)
        case "${STUB_CRASH:-}" in
          old_keyerror)
            if [ "$2" = malachi-cluster-2 ] && [ "${running##*:}" = old ] && [ ! -f "$STUB_LOG.crashed" ]; then
              touch "$STUB_LOG.crashed"
              echo "12:00:00.000 [error] GenServer Malachi.LogReplication terminating"
              echo "** (KeyError) key :records not found in: %{batch: []}"
            fi ;;
          old_timeout | new_timeout | data_timeout)
            if [ "$2" = malachi-cluster-2 ] && [ "${running##*:}" = "${STUB_CRASH%_timeout}" ] && [ ! -f "$STUB_LOG.crashed" ]; then
              touch "$STUB_LOG.crashed"
              echo "12:00:00.000 [error] GenServer Malachi.LogHealer terminating"
              echo "** (stop) exited in: GenServer.call(Malachi.LogBroker, :metadata, 5000)"
              echo "    ** (EXIT) time out"
            fi ;;
          old_apply_heal_timeout)
            if [ "$2" = malachi-cluster-2 ] && [ "${running##*:}" = old ] && [ ! -f "$STUB_LOG.crashed" ]; then
              touch "$STUB_LOG.crashed"
              echo "12:00:00.000 [error] GenServer Malachi.LogHealer terminating"
              echo "** (stop) exited in: GenServer.call(Malachi.LogBroker, {:apply_heal, [{:set_segment_replicas, {{\"t\", 0}, 0}, []}]}, 5000)"
              echo "    ** (EXIT) time out"
            fi ;;
        esac ;;
      run)
        case "$*" in
          *"chaos_checker.exs produce"*)
            prev=""
            for a in "$@"; do
              if [ "$prev" = -v ] && [ "${a%:/chaos}" != "$a" ]; then
                if [ "${STUB_DATA_ACKS:-}" = 0 ] && [[ "$*" == *repo-upgrade:data* ]]; then
                  : > "${a%:/chaos}/acked.log"
                else
                  echo c-1 > "${a%:/chaos}/acked.log"
                fi
                echo "${a%:/chaos}/acked.log" > "$acked_file"
              fi
              prev="$a"
            done ;;
          *"chaos_checker.exs verify"*)
            echo "acked=1 read=1 missing=0"
            echo "VERIFY OK: every acknowledged write survived" ;;
          *"chaos_checker.exs control-plane"*)
            if [ "${STUB_CONTROL_PLANE:-}" = diverged ]; then
              echo "CONTROL-PLANE MISMATCH group=malachi_log_vn_0 index=4 state differs: a=1 b=2 c=1 outliers=b"
              echo "CONTROL-PLANE DIVERGED projection=topics"
              exit 1
            fi
            echo "CONTROL-PLANE OK groups=12 projection=all" ;;
          *md5sum*)
            n=$(( $(cat "$STUB_LOG.md5" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$STUB_LOG.md5"
            echo "aaa  ./malachi.format"
            if [ "${STUB_MD5_CHANGES:-}" = 1 ] && [ "$n" -gt 1 ]; then echo "ccc  ./seg.log"; else echo "bbb  ./seg.log"; fi ;;
          *"--host ${STUB_PRODUCE_FAILS_ON:-none} "*) echo '{"errors":5,"dropped":0,"records_per_s":0}' ;;
          *--scenario*) echo '{"errors":0,"dropped":0,"records_per_s":100}' ;;
          *) : ;;
        esac ;;
      *) : ;;
    esac
    exit 0
    """
  end
end
