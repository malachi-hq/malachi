defmodule ValidateDockerBuildTest do
  # scripts/validate-docker-build.sh is the second half of `make docker-build docker-validate`, the gate a
  # base image update and the auth and observability Hex tiers run. Its first step checks, inside the
  # image, that the argon2 NIF is in the release and that OTP's crypto NIF loads libcrypto. Before #331
  # that step could not fail: each check ended in `|| (echo ... && exit 1)`, whose exit leaves only the
  # subshell, and it asked for the openssl CLI, which no Alpine base ships, so it printed an ERROR and
  # passed on every image. Here the step's own shell body runs for real under sh, with a `find` and a
  # `bin/malachi` that answer each case, so its exit status is what is checked, not its text.
  use ExUnit.Case, async: true

  alias Malachi.Test.DockerHarnessStubs, as: Stubs
  alias Malachi.Test.TmpDir

  @script Path.expand("../../scripts/validate-docker-build.sh", __DIR__)
  @scripts Path.expand("../../scripts", __DIR__)
  @passwords ~w(MALACHI_ADMIN_PASS MALACHI_PRODUCER_PASS MALACHI_CONSUMER_PASS MALACHI_APP_PASS)

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    System.find_executable("sh") || flunk("sh is required to test scripts/validate-docker-build.sh")
    :ok
  end

  setup do
    dir = TmpDir.path("validate-docker-build")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # The body the script hands to `sh -c` in the image for step 1, unescaped the way bash would pass it.
  defp step_one_body do
    [_, after_step] = @script |> File.read!() |> String.split("Step 1:", parts: 2)
    [_, from_body] = String.split(after_step, ~s(-c "), parts: 2)
    [body, _] = String.split(from_body, ~s(\n" ||), parts: 2)
    String.replace(body, ~S(\"), ~S("))
  end

  # Runs the body in `dir` with stubs: `find` prints the argon2 NIF path or nothing, and `bin/malachi`
  # exits with the given status, recording the expression it was asked to eval.
  defp run_step(dir, argon2?: argon2?, eval_status: eval_status) do
    bin = Path.join(dir, "stub-bin")
    File.mkdir_p!(bin)
    found = if argon2?, do: "echo /app/lib/argon2_elixir-4.1.3/priv/argon2_nif.so", else: "true"
    stub!(Path.join(bin, "find"), found)

    File.mkdir_p!(Path.join(dir, "bin"))
    stub!(Path.join(dir, "bin/malachi"), ~s(printf '%s' "$2" > "#{dir}/eval.txt"; exit #{eval_status}))

    System.cmd("sh", ["-c", step_one_body()],
      cd: dir,
      env: [{"PATH", bin <> ":" <> System.get_env("PATH")}],
      stderr_to_stdout: true
    )
  end

  defp stub!(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  test "passes when the argon2 NIF is there and the crypto NIF loads", %{dir: dir} do
    assert {output, 0} = run_step(dir, argon2?: true, eval_status: 0)
    assert output =~ "All runtime dependencies present"
  end

  test "fails when the crypto NIF cannot load libcrypto, before claiming everything is present", %{dir: dir} do
    assert {output, status} = run_step(dir, argon2?: true, eval_status: 1)
    assert status != 0
    assert output =~ "ERROR: crypto NIF could not load libcrypto"
    refute output =~ "All runtime dependencies present"
  end

  test "fails when the argon2 NIF is missing, without going on to the crypto check", %{dir: dir} do
    assert {output, status} = run_step(dir, argon2?: false, eval_status: 0)
    assert status != 0
    assert output =~ "ERROR: argon2 NIF not found"
    refute File.exists?(Path.join(dir, "eval.txt"))
  end

  test "decides on the eval's exit status, matching the OpenSSL tuple rather than grepping the output", %{dir: dir} do
    assert {_, 0} = run_step(dir, argon2?: true, eval_status: 0)

    assert File.read!(Path.join(dir, "eval.txt")) ==
             ~s|match?([{"OpenSSL", _, _}], :crypto.info_lib()) or System.halt(1)|

    refute step_one_body() =~ "grep -q 'OpenSSL'"
    refute step_one_body() =~ "which openssl"
  end

  # #180: the whole script, run in a throwaway tree with Malachi.Test.DockerHarnessStubs first on the PATH.
  # The passwords reach the container by name (`docker run -e NAME`, MALACHI_DEFAULT_USERS included), the
  # login body and the bearer reach curl on stdin, and none of them is ever a process argument.
  describe "a full run" do
    setup %{dir: dir} do
      tree = Path.join(dir, "tree")
      File.mkdir_p!(Path.join([tree, "scripts", "lib"]))

      for file <- ~w(validate-docker-build.sh metrics_scrape_lib.sh lib/dashboard_curl.sh) do
        File.cp!(Path.join(@scripts, file), Path.join([tree, "scripts", file]))
      end

      # The script reads the version from the mix.exs of the directory it runs in.
      File.write!(Path.join(tree, "mix.exs"), ~s(  @version "9.9.9"\n))
      Map.merge(Stubs.install!(dir), %{tree: tree})
    end

    test "passes, with every password and the session token off every process argument", ctx do
      assert {output, 0} = run_full(ctx)
      assert output =~ "Dashboard authentication successful"
      assert output =~ "Dashboard responding"
      assert output =~ "All validation checks completed"

      env = Stubs.container_env(ctx)
      argv = Stubs.argv(ctx)
      assert argv =~ "hectorcardoso/malachi:9.9.9"

      for var <- @passwords do
        assert env[var] =~ ~r/^validation_/, "#{var} did not reach the container"
        assert argv =~ "-e #{var} "
        refute argv =~ env[var], "#{var}'s value reached a process argument"
      end

      assert env["MALACHI_DEFAULT_USERS"] ==
               "admin:#{env["MALACHI_ADMIN_PASS"]}:admin;producer:#{env["MALACHI_PRODUCER_PASS"]}:produce;" <>
                 "consumer:#{env["MALACHI_CONSUMER_PASS"]}:consume;app:#{env["MALACHI_APP_PASS"]}:produce,consume"

      assert argv =~ "-e MALACHI_DEFAULT_USERS "
      refute argv =~ "stub-token"
      refute argv =~ "Bearer"

      assert [login, bearer] = Stubs.curl_stdin(ctx)
      assert Jason.decode!(login) == %{"username" => "admin", "password" => env["MALACHI_ADMIN_PASS"]}
      assert bearer == ~s(header = "Authorization: Bearer stub-token"\n)
    end

    for {behavior, reason} <- [
          {"login403", "login failed: HTTP 403 (the dashboard refused the credentials)"},
          {"badtoken", "login failed: the answer carried a malformed token"}
        ] do
      test "#{behavior}: every attempt fails and the run stops, saying why", ctx do
        assert {output, 1} = run_full(ctx, [{"STUB_CURL", unquote(behavior)}])
        assert output =~ "Could not authenticate to dashboard after 10 attempts (#{unquote(reason)})"
        assert length(Stubs.curl_stdin(ctx)) == 10
        refute output =~ "Step 4"
      end
    end

    test "without jq it refuses to start, before touching docker", ctx do
      bin = Path.join(ctx.dir, "bin")
      File.mkdir_p!(bin)

      for tool <- ~w(bash dirname grep head sed curl) do
        File.ln_s!(System.find_executable(tool), Path.join(bin, tool))
      end

      assert {output, 1} = run_full(ctx, [{"PATH", bin}])
      assert output =~ "jq is required"
      refute File.exists?(ctx.argv_log)
    end
  end

  defp run_full(ctx, env \\ []) do
    System.cmd(System.find_executable("bash"), [Path.join([ctx.tree, "scripts", "validate-docker-build.sh"])],
      cd: ctx.tree,
      env: Stubs.env(ctx, env),
      stderr_to_stdout: true
    )
  end
end
