defmodule LoadtestAbTest do
  # benchmark/loadtest_ab.sh runs the Node generator in a stock Node image and the Elixir one in the bench
  # compose's loadtest image, both against a bench server whose only user is the dev admin. #180, and the
  # two generators kept equivalent: the script sets that login itself, and hands it to BOTH containers by
  # name (`-e MALACHI_USER -e MALACHI_PASS`), so neither password is ever an argument of the docker client
  # and both generators authenticate the same way, from the environment. The script runs for real, one case
  # per generator and one repetition, with Malachi.Test.DockerHarnessStubs first on the PATH and `mix` (the
  # analysis at the end) stubbed out.
  use ExUnit.Case, async: true

  alias Malachi.Test.DockerHarnessStubs, as: Stubs

  @moduletag :tmp_dir

  @script Path.expand("../../benchmark/loadtest_ab.sh", __DIR__)

  setup %{tmp_dir: dir} do
    paths = Stubs.install!(dir)
    mix = Path.join(paths.stubs, "mix")
    File.write!(mix, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(mix, 0o755)
    Map.put(paths, :out, Path.join(dir, "results"))
  end

  for {name, exported} <- [
        {"with nothing exported", [{"MALACHI_USER", nil}, {"MALACHI_PASS", nil}]},
        {"with another login exported", [{"MALACHI_USER", "bench"}, {"MALACHI_PASS", "s3cret"}]}
      ] do
    test "both generators log in as the bench admin by name, #{name}", ctx do
      env = [{"AB_CASES", "payload-node-b10 payload-elixir-b10"}, {"AB_REPS", "1"}] ++ unquote(exported)

      assert {_output, 0} =
               System.cmd(System.find_executable("bash"), [@script, "payload", ctx.out],
                 env: Stubs.env(ctx, env),
                 stderr_to_stdout: true
               )

      generators = ctx |> Stubs.argv() |> String.split("\n") |> Enum.filter(&(&1 =~ " --scenario produce "))
      node = Enum.filter(generators, &(&1 =~ "node scripts/loadtest.js"))
      elixir = Enum.filter(generators, &(&1 =~ ~r/ loadtest --host malachi /))
      assert node != [] and elixir != []

      for call <- generators do
        assert call =~ "-e MALACHI_USER -e MALACHI_PASS "
        refute call =~ "admin123"
        refute call =~ "s3cret"
      end

      env_log = File.read!(ctx.env_log)
      refute env_log =~ "bench"
      refute env_log =~ "s3cret"

      assert Stubs.container_env(ctx) |> Map.take(["MALACHI_USER", "MALACHI_PASS"]) ==
               %{"MALACHI_USER" => "admin", "MALACHI_PASS" => "admin123"}

      # Every generator container, Node and Elixir, got the login: one pair of -e per run.
      assert length(Regex.scan(~r/^MALACHI_PASS=admin123$/m, env_log)) == length(generators)
    end
  end
end
