defmodule ReleaseEnvTest do
  # rel/env.sh.eex (#385), the release's hook before the VM starts: a clustered node refused before it listens on a
  # cookie anyone can read or on plaintext distribution it did not opt into, a single node given a cookie of its own
  # on every start (the image ships none), and distribution bound to MALACHI_DIST_INTERFACE. The template is rendered
  # as `mix release` renders it, then sourced by sh with the environment each case sets, as bin/malachi sources it.
  # Linux only: the hook reads file owners and modes with GNU/BusyBox stat, and Malachi runs on Linux only.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.DistGuard

  @moduletag :tmp_dir
  @moduletag :linux

  @template Path.expand("../../rel/env.sh.eex", __DIR__)
  @cookie String.duplicate("c0ffee", 8)

  # Every variable the hook reads, unset unless a case sets it, so the shell running the suite changes nothing.
  @vars ~w(MALACHI_DIST_TLS MALACHI_DIST_TLS_OPTFILE MALACHI_DIST_INTERFACE MALACHI_CLUSTER_STRATEGY MALACHI_LOG_NODES
           RELEASE_COOKIE MALACHI_COOKIE_DIR ELIXIR_ERL_OPTIONS ERL_EPMD_ADDRESS RELEASE_ROOT RELEASE_COMMAND TMPDIR)

  setup %{tmp_dir: dir} do
    envsh = Path.join(dir, "env.sh")
    File.write!(envsh, EEx.eval_file(@template, []))
    %{envsh: envsh, cookies: Path.join(dir, "cookies"), root: dir}
  end

  # Sources the hook as bin/malachi does for `command`, and reads back what it exported: {exported, output, status}.
  defp source(ctx, command, env) do
    env = Map.merge(%{"MALACHI_COOKIE_DIR" => ctx.cookies, "RELEASE_ROOT" => ctx.root}, Map.new(env))
    env = for var <- @vars, do: {var, Map.get(env, var) || Map.get(env, String.to_atom(var))}
    env = [{"RELEASE_COMMAND", command} | Enum.reject(env, &(elem(&1, 0) == "RELEASE_COMMAND"))]

    script =
      ~S|. "$0"; printf 'COOKIE=%s\nOPTS=%s\nEPMD=%s\nARG1=%s\n' "$RELEASE_COOKIE" "$ELIXIR_ERL_OPTIONS" "$ERL_EPMD_ADDRESS" "$1"|

    {out, status} = System.cmd("sh", ["-c", script, ctx.envsh, command], env: env, stderr_to_stdout: true)

    exported =
      for line <- String.split(out, "\n"),
          [_, k, v] <- [Regex.run(~r/\A([A-Z0-9]+)=(.*)\z/, line)],
          into: %{},
          do: {k, v}

    {exported, out, status}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp verified_conf(ctx) do
    path = Path.join(ctx.root, "dist_tls.conf")

    File.write!(path, """
    [{server, [{verify, verify_peer}, {fail_if_no_peer_cert, true}]},
     {client, [{verify, verify_peer}]}].
    """)

    path
  end

  describe "a single node without RELEASE_COOKIE" do
    test "start writes a fresh random cookie, private, and exports it", ctx do
      {%{"COOKIE" => cookie}, _out, 0} = source(ctx, "start", [])
      assert cookie =~ ~r/\A[0-9a-f]{64}\z/
      assert File.read!(Path.join(ctx.cookies, "COOKIE")) == cookie
      assert mode(ctx.cookies) == 0o700
      assert mode(Path.join(ctx.cookies, "COOKIE")) == 0o600
      assert File.ls!(ctx.cookies) == ["COOKIE"]

      {%{"COOKIE" => again}, _out, 0} = source(ctx, "daemon", [])
      refute again == cookie
    end

    test "rpc, remote and stop reach the running node with the cookie start wrote", ctx do
      {%{"COOKIE" => cookie}, _out, 0} = source(ctx, "start", [])

      for command <- ~w(rpc remote stop pid restart) do
        assert {%{"COOKIE" => ^cookie}, _out, 0} = source(ctx, command, [])
      end
    end

    test "rpc with no running node's cookie refuses, saying where it looked", ctx do
      {_exported, out, 1} = source(ctx, "rpc", [])
      assert out =~ "no cookie of a running node at #{ctx.cookies}/COOKIE"
    end

    test "a cookie file another user could read, or a link, is refused", ctx do
      {_exported, _out, 0} = source(ctx, "start", [])
      file = Path.join(ctx.cookies, "COOKIE")

      File.chmod!(file, 0o644)
      assert {_e, _o, 1} = source(ctx, "rpc", [])

      File.chmod!(file, 0o600)
      File.rename!(file, file <> ".real")
      File.ln_s!(file <> ".real", file)
      assert {_e, _o, 1} = source(ctx, "rpc", [])
    end

    test "a cookie directory others can enter is refused on start, and nothing is written in it", ctx do
      File.mkdir_p!(ctx.cookies)
      File.chmod!(ctx.cookies, 0o755)
      {_exported, out, 1} = source(ctx, "start", [])
      assert out =~ "is not a directory of this user's own with mode 700"
      assert File.ls!(ctx.cookies) == []
    end

    test "a cookie directory that is a link is refused on start", ctx do
      target = Path.join(ctx.root, "elsewhere")
      File.mkdir_p!(target)
      File.chmod!(target, 0o700)
      File.ln_s!(target, ctx.cookies)
      assert {_e, _o, 1} = source(ctx, "start", [])
      assert File.ls!(target) == []
    end

    test "eval with no running node gets a random cookie and writes nothing", ctx do
      {%{"COOKIE" => cookie}, _out, 0} = source(ctx, "eval", [])
      assert cookie =~ ~r/\A[0-9a-f]{64}\z/
      refute File.exists?(ctx.cookies)
    end

    test "a RELEASE_COOKIE given is kept, and no directory is made", ctx do
      assert {%{"COOKIE" => @cookie}, _out, 0} = source(ctx, "start", RELEASE_COOKIE: @cookie)
      refute File.exists?(ctx.cookies)
    end

    test "the command stays in $1 for bin/malachi after the hook", ctx do
      assert {%{"ARG1" => "start"}, _out, 0} = source(ctx, "start", MALACHI_DIST_INTERFACE: "10.0.0.5")
    end
  end

  describe "a clustered node" do
    @tls [MALACHI_CLUSTER_STRATEGY: "epmd", MALACHI_DIST_TLS: "true", RELEASE_COOKIE: @cookie]

    test "with its own cookie over verified TLS starts, with inet_tls and the options file", ctx do
      conf = verified_conf(ctx)
      {%{"OPTS" => opts, "COOKIE" => @cookie}, _out, 0} = source(ctx, "start", @tls ++ [MALACHI_DIST_TLS_OPTFILE: conf])
      assert opts =~ "-proto_dist inet_tls -ssl_dist_optfile #{conf}"
      refute File.exists?(ctx.cookies)
    end

    test "more than one MALACHI_LOG_NODES makes a node clustered, one does not", ctx do
      {_e, out, 1} = source(ctx, "start", MALACHI_LOG_NODES: "malachi@a,malachi@b")
      assert out =~ "RELEASE_COOKIE is not set"

      assert {_e, _o, 0} = source(ctx, "start", MALACHI_LOG_NODES: "malachi@a")
      assert {_e, _o, 0} = source(ctx, "start", MALACHI_LOG_NODES: "malachi@a,")
    end

    test "without RELEASE_COOKIE refuses, on every command", ctx do
      for command <- ~w(start rpc eval) do
        {_e, out, 1} = source(ctx, command, MALACHI_CLUSTER_STRATEGY: "epmd")
        assert out =~ "this node is clustered and RELEASE_COOKIE is not set"
      end
    end

    test "every committed cookie is refused, and the message never holds it", ctx do
      conf = verified_conf(ctx)

      for cookie <- DistGuard.denylist() do
        env = Keyword.merge(@tls, RELEASE_COOKIE: cookie, MALACHI_DIST_TLS_OPTFILE: conf)
        {_e, out, 1} = source(ctx, "start", env)
        assert out =~ "a value committed to the Malachi repository"
        refute out =~ cookie
      end
    end

    test "a cookie under 20 bytes is refused, and one of 20 passes", ctx do
      conf = verified_conf(ctx)
      short = Keyword.merge(@tls, RELEASE_COOKIE: String.duplicate("a", 19), MALACHI_DIST_TLS_OPTFILE: conf)
      assert {_e, _o, 1} = source(ctx, "start", short)
      enough = Keyword.merge(@tls, RELEASE_COOKIE: String.duplicate("a", 20), MALACHI_DIST_TLS_OPTFILE: conf)
      assert {_e, _o, 0} = source(ctx, "start", enough)
    end

    test "the release's baked cookie is refused when it is given back as RELEASE_COOKIE", ctx do
      File.mkdir_p!(Path.join(ctx.root, "releases"))
      File.write!(Path.join([ctx.root, "releases", "COOKIE"]), @cookie)
      {_e, out, 1} = source(ctx, "start", @tls ++ [MALACHI_DIST_TLS_OPTFILE: verified_conf(ctx)])
      assert out =~ "the cookie baked into the release"
    end

    test "plaintext is refused unless MALACHI_DIST_TLS=false, which warns", ctx do
      {_e, out, 1} = source(ctx, "start", MALACHI_CLUSTER_STRATEGY: "epmd", RELEASE_COOKIE: @cookie)
      assert out =~ "would run in plaintext"

      {%{"OPTS" => opts}, out, 0} =
        source(ctx, "start", MALACHI_CLUSTER_STRATEGY: "epmd", RELEASE_COOKIE: @cookie, MALACHI_DIST_TLS: "false")

      assert out =~ "warning: MALACHI_DIST_TLS=false"
      refute opts =~ "inet_tls"
    end

    test "an options file that does not verify the peers both ways is refused", ctx do
      conf = Path.join(ctx.root, "weak.conf")
      File.write!(conf, "[{server, [{verify, verify_none}]}, {client, [{verify, verify_peer}]}].\n")
      {_e, out, 1} = source(ctx, "start", @tls ++ [MALACHI_DIST_TLS_OPTFILE: conf])
      assert out =~ "does not verify the peers both ways"
    end
  end

  describe "the transport switch and the interface, in every mode" do
    test "MALACHI_DIST_TLS other than true, false or unset is refused", ctx do
      for value <- ~w(TRUE yes 1 off) do
        {_e, out, 1} = source(ctx, "start", MALACHI_DIST_TLS: value)
        assert out =~ "MALACHI_DIST_TLS must be true, false or unset"
      end
    end

    test "TLS without a readable options file is refused", ctx do
      assert {_e, _o, 1} = source(ctx, "start", MALACHI_DIST_TLS: "true")
      assert {_e, _o, 1} = source(ctx, "start", MALACHI_DIST_TLS: "true", MALACHI_DIST_TLS_OPTFILE: "/nowhere.conf")
    end

    test "MALACHI_DIST_INTERFACE binds epmd and distribution to that address", ctx do
      {exported, _out, 0} = source(ctx, "start", MALACHI_DIST_INTERFACE: "10.0.0.5")
      assert exported["EPMD"] == "10.0.0.5"
      assert exported["OPTS"] =~ "-kernel inet_dist_use_interface {10,0,0,5}"
    end

    test "anything but an IPv4 address is refused as the interface", ctx do
      for bad <- ["10.0.0.256", "10.0.0", "10.0.0.5.6", "::1", "10.0.0.5 -eval x", "a.b.c.d", "010.0.0.0005", "."] do
        {_e, out, 1} = source(ctx, "start", MALACHI_DIST_INTERFACE: bad)
        assert out =~ "MALACHI_DIST_INTERFACE must be an IPv4 address", bad
      end
    end
  end

  test "the template takes the denylist and the minimum length from Malachi.Cluster.DistGuard", ctx do
    rendered = File.read!(ctx.envsh)
    assert rendered =~ Enum.join(DistGuard.denylist(), " | ")
    assert rendered =~ "-ge #{DistGuard.min_cookie_bytes()} ]"
  end
end
