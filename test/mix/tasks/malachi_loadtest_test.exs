defmodule Mix.Tasks.Malachi.LoadtestTest do
  # The mix task's own job since #180: the login comes from the environment, never from a flag, because a
  # process argument is readable by every local user in /proc/<pid>/cmdline for as long as the run lasts.
  # `credentials/2` is pure and tested on maps; one integration case runs the task against the test server
  # with the variables really set, which is why the module is not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Malachi.TCPAcceptorPool
  alias Malachi.Test.LoadtestEnv
  alias Malachi.Test.RouterTopology
  alias Mix.Tasks.Malachi.Loadtest, as: Task

  describe "credentials/2" do
    test "reads the user, the password and the token from the environment" do
      env = %{"MALACHI_USER" => "bench", "MALACHI_PASS" => "s3cret", "MALACHI_TOKEN" => "tok"}
      assert Task.credentials([duration: 1], env) == [token: "tok", pass: "s3cret", user: "bench", duration: 1]
    end

    test "--user wins over MALACHI_USER" do
      assert Task.credentials([user: "flag"], %{"MALACHI_USER" => "env"}) == [user: "flag"]
    end

    test "an empty variable counts as unset, as scripts/lib/cli.js reads it" do
      env = %{"MALACHI_USER" => "", "MALACHI_PASS" => "", "MALACHI_TOKEN" => ""}
      assert Task.credentials([duration: 1], env) == [duration: 1]
    end

    test "with nothing set nothing is added, so the connection's defaults apply" do
      assert Task.credentials([], %{"PATH" => "/bin"}) == []
    end

    # The precedence the moduledoc states: the token is added beside the certificate and the named user,
    # and Malachi.Loadtest.Conn.authenticate/2 takes a token first.
    test "a MALACHI_TOKEN is added even beside --cert and --user, and MALACHI_PASS beside --user" do
      opts =
        Task.credentials([cert: "c.pem", key: "k.pem", user: "flag"], %{"MALACHI_TOKEN" => "t", "MALACHI_PASS" => "p"})

      assert Map.new(Keyword.take(opts, [:token, :pass, :user, :cert])) ==
               %{token: "t", pass: "p", user: "flag", cert: "c.pem"}
    end

    test "each variable is read on its own" do
      assert Task.credentials([], %{"MALACHI_PASS" => "p"}) == [pass: "p"]
      assert Task.credentials([], %{"MALACHI_TOKEN" => "t"}) == [token: "t"]
      assert Task.credentials([], %{"MALACHI_USER" => "u"}) == [user: "u"]
    end
  end

  describe "the flags" do
    for flag <- ~w(--pass --token) do
      test "#{flag} is refused before anything connects" do
        assert_raise OptionParser.ParseError, ~r/#{unquote(flag)} : Unknown option/, fn ->
          Task.run([unquote(flag), "secret", "--duration", "1"])
        end
      end
    end
  end

  describe "against the test server" do
    setup {RouterTopology, :clear}

    setup do
      :ok = LoadtestEnv.isolate()

      user = "lt_env_#{System.unique_integer([:positive])}"
      password = "Env-Pass-#{System.unique_integer([:positive])}!"
      :ok = Malachi.Auth.add_user(user, password, [:produce, :consume, :admin])
      on_exit(fn -> Malachi.Auth.remove_user(user) end)
      %{user: user, password: password}
    end

    test "authenticates as MALACHI_USER with MALACHI_PASS, and the password stays out of the report", ctx do
      System.put_env("MALACHI_USER", ctx.user)
      System.put_env("MALACHI_PASS", ctx.password)

      output = capture_io(fn -> Task.run(argv()) end)

      report = Jason.decode!(output)
      assert report["errors"] == 0
      assert report["records_per_s"] > 0
      assert report["meta"]["command"] =~ "--user=#{ctx.user}"
      refute output =~ ctx.password
    end

    test "a wrong MALACHI_PASS fails the run, so the variable is what was sent", ctx do
      System.put_env("MALACHI_USER", ctx.user)
      System.put_env("MALACHI_PASS", "not-" <> ctx.password)

      assert_raise Mix.Error, fn -> capture_io(fn -> Task.run(argv()) end) end
    end
  end

  defp argv do
    ~w(--scenario produce --connections 1 --batch 2 --duration 1 --warmup 0 --json) ++
      ["--port", Integer.to_string(TCPAcceptorPool.port()), "--topic", "lt_env_#{System.unique_integer([:positive])}"]
  end
end
