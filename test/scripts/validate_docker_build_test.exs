defmodule ValidateDockerBuildTest do
  # scripts/validate-docker-build.sh is the second half of `make docker-build docker-validate`, the gate a
  # base image update and the auth and observability Hex tiers run. Its first step checks, inside the
  # image, that the argon2 NIF is in the release and that OTP's crypto NIF loads libcrypto. Before #331
  # that step could not fail: each check ended in `|| (echo ... && exit 1)`, whose exit leaves only the
  # subshell, and it asked for the openssl CLI, which no Alpine base ships, so it printed an ERROR and
  # passed on every image. Here the step's own shell body runs for real under sh, with a `find` and a
  # `bin/malachi` that answer each case, so its exit status is what is checked, not its text.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @script Path.expand("../../scripts/validate-docker-build.sh", __DIR__)

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
end
