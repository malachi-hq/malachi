defmodule CheckImageRuntimeTest do
  # scripts/check-image-runtime.sh is what keeps the images and the tests on one runtime (#332): the CI
  # jobs install Erlang/OTP and Elixir from .github/beam-versions, the images take them from an elixir base
  # image whose tag floats under its digest, and the Docker Build Test runs this check to compare the two.
  # Here it runs for real against fixture Dockerfiles, with a PATH whose `docker` prints, per image digest,
  # whatever the case needs, so every way it can pass or fail is exercised without Docker. The script bounds
  # each image read with the real coreutils `timeout`, which is why this module is Linux only. The read
  # itself, against the real base images, is what the CI step runs.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @moduletag :linux

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/check-image-runtime.sh")
  @versions_file Path.join(@root, ".github/beam-versions")
  @workflows Path.join(@root, ".github/workflows")

  @a "sha256:" <> String.duplicate("a", 64)
  @b "sha256:" <> String.duplicate("b", 64)
  @image_a "elixir:1.19-otp-28-alpine@" <> @a
  @image_b "elixir:1.19-otp-28-alpine@" <> @b

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    for tool <- ~w(bash awk grep sed wc tr cat timeout) do
      System.find_executable(tool) || flunk("#{tool} is required to test scripts/check-image-runtime.sh")
    end

    :ok
  end

  setup do
    dir = TmpDir.path("check-image-runtime")
    # Exclusive: a directory already there is a leftover, and building on it would test the leftover.
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    stub_bin = Path.join(dir, "stub-bin")
    stub_data = Path.join(dir, "stub-data")
    File.mkdir_p!(stub_bin)
    File.mkdir_p!(stub_data)
    stub_docker!(stub_bin, stub_data)

    versions = Path.join(dir, "beam-versions")
    File.write!(versions, "# comment\nerlang 28.5.0.2\nelixir 1.19.5-otp-28\n")

    %{dir: dir, stub_bin: stub_bin, stub_data: stub_data, versions: versions}
  end

  # A `docker` that appends its arguments to docker-args (one per line, then a `--` line), and answers for
  # the image digest in its seventh argument (`run --rm --platform linux/amd64 --entrypoint sh <image>`):
  # hangs <digest>.sleep seconds if that file exists (`exec` so the check's timeout stops the sleep itself),
  # else prints <digest>.out (or default.out) and exits with <digest>.status (default 0).
  defp stub_docker!(stub_bin, stub_data) do
    path = Path.join(stub_bin, "docker")

    File.write!(path, """
    #!/bin/sh
    { printf '%s\\n' "$@"; echo --; } >> "#{stub_data}/docker-args"
    key=$(printf '%s' "$7" | sed 's/.*@sha256://')
    [ -f "#{stub_data}/$key.sleep" ] && exec sleep "$(cat "#{stub_data}/$key.sleep")"
    if [ -f "#{stub_data}/$key.out" ]; then cat "#{stub_data}/$key.out"; else cat "#{stub_data}/default.out" 2>/dev/null; fi
    exit "$(cat "#{stub_data}/$key.status" 2>/dev/null || echo 0)"
    """)

    File.chmod!(path, 0o755)
  end

  defp image_answers!(ctx, digest, output, status \\ 0) do
    key = String.replace_prefix(digest, "sha256:", "")
    File.write!(Path.join(ctx.stub_data, "#{key}.out"), output)
    File.write!(Path.join(ctx.stub_data, "#{key}.status"), Integer.to_string(status))
  end

  defp dockerfile!(ctx, name, body) do
    path = Path.join(ctx.dir, name)
    File.write!(path, body)
    path
  end

  defp docker_calls(ctx) do
    case File.read(Path.join(ctx.stub_data, "docker-args")) do
      {:ok, text} -> text |> String.split("--\n", trim: true) |> Enum.map(&String.split(&1, "\n", trim: true))
      {:error, :enoent} -> []
    end
  end

  defp run(ctx, args, env \\ []) do
    path = "#{ctx.stub_bin}:#{System.get_env("PATH")}"
    System.cmd("bash", [@script | args], env: [{"PATH", path} | env], stderr_to_stdout: true)
  end

  defp root_and_bench!(ctx, bench_image \\ @image_a) do
    root =
      dockerfile!(ctx, "Dockerfile", """
      FROM #{@image_a} AS builder
      RUN mix release
      FROM alpine:3.21@sha256:#{String.duplicate("c", 64)}
      COPY --from=builder /app /app
      """)

    bench = dockerfile!(ctx, "Dockerfile.loadtest", "# load generator\nFROM #{bench_image}\n")
    {root, bench}
  end

  # What the probe prints for an image that matches the fixture pins.
  @matching "OTP=28.5.0.2\nELIXIR=1.19.5\n"

  describe "passes" do
    test "when every elixir base image ships the pinned OTP and Elixir", ctx do
      {root, bench} = root_and_bench!(ctx, @image_b)
      image_answers!(ctx, @a, @matching)
      image_answers!(ctx, @b, @matching)

      assert {out, 0} = run(ctx, [ctx.versions, root, bench])
      assert out =~ "#{root}: #{@image_a} ships OTP 28.5.0.2 and Elixir 1.19.5, as #{ctx.versions} pins"
      assert out =~ "#{bench}: #{@image_b} ships OTP 28.5.0.2 and Elixir 1.19.5"
    end

    test "reading an image both Dockerfiles share once, and saying so for the second", ctx do
      {root, bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, @matching)

      assert {out, 0} = run(ctx, [ctx.versions, root, bench])
      assert out =~ "#{bench}: #{@image_a}, compared above"
      assert length(docker_calls(ctx)) == 1
    end

    test "reading the base image itself as linux/amd64, never the alpine runtime stage", ctx do
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, @matching)

      assert {_out, 0} = run(ctx, [ctx.versions, root])
      assert [call] = docker_calls(ctx)
      assert Enum.take(call, 8) == ~w(run --rm --platform linux/amd64 --entrypoint sh) ++ [@image_a, "-c"]
      assert Enum.join(Enum.drop(call, 8), "\n") =~ "/usr/local/lib/erlang/releases/*/OTP_VERSION"
      assert Enum.join(Enum.drop(call, 8), "\n") =~ "/usr/local/lib/elixir/lib/elixir/ebin/elixir.app"
    end

    test "with output around the sentinel lines", ctx do
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, "Unable to find image locally\nPulling...\nOTP=28.5.0.2\nnoise\nELIXIR=1.19.5\n")

      assert {_out, 0} = run(ctx, [ctx.versions, root])
    end

    test "with every FROM spelling the elixir image takes", ctx do
      for {from, n} <-
            Enum.with_index([
              "FROM #{@image_a}",
              "from #{@image_a} as builder",
              "FROM --platform=$BUILDPLATFORM #{@image_a} AS builder",
              "FROM docker.io/library/#{@image_a}",
              "FROM elixir@#{@a}"
            ]) do
        File.rm(Path.join(ctx.stub_data, "docker-args"))
        file = dockerfile!(ctx, "Dockerfile.#{n}", from <> "\n")
        File.write!(Path.join(ctx.stub_data, "default.out"), @matching)

        {out, status} = run(ctx, [ctx.versions, file])
        assert status == 0, "#{from}: #{out}"
        assert [_call] = docker_calls(ctx)
      end
    end

    test "on the repository's own versions file and Dockerfiles", ctx do
      # Pins the parsing to the real files: the probe answers with what .github/beam-versions pins.
      [otp] = Regex.run(~r/^erlang (\S+)$/m, File.read!(@versions_file), capture: :all_but_first)
      [elixir] = Regex.run(~r/^elixir (\S+)-otp-\d+$/m, File.read!(@versions_file), capture: :all_but_first)
      File.write!(Path.join(ctx.stub_data, "default.out"), "OTP=#{otp}\nELIXIR=#{elixir}\n")

      assert {out, 0} =
               run(ctx, [
                 @versions_file,
                 Path.join(@root, "Dockerfile"),
                 Path.join(@root, "benchmark/Dockerfile.loadtest")
               ])

      assert out =~ "ships OTP #{otp} and Elixir #{elixir}"
    end

    test "finds its helper when run by bare name from the scripts directory", ctx do
      # $0 has no slash then, which is the one way to reach the fallback that sources the helper from `.`.
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, @matching)

      assert {out, 0} =
               System.cmd("bash", [Path.basename(@script), ctx.versions, root],
                 cd: Path.dirname(@script),
                 env: [{"PATH", "#{ctx.stub_bin}:#{System.get_env("PATH")}"}],
                 stderr_to_stdout: true
               )

      assert out =~ "ships OTP 28.5.0.2"
    end
  end

  describe "fails naming the Dockerfile, the image and both versions" do
    test "when an OTP patch moves and leaves erts alone, as 28.5.0.7 does", ctx do
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, "OTP=28.5.0.7\nELIXIR=1.19.5\n")

      assert {out, 1} = run(ctx, [ctx.versions, root])

      assert out =~
               "FAIL: #{root} builds from #{@image_a}, which ships OTP 28.5.0.7 and Elixir 1.19.5, but #{ctx.versions} pins OTP 28.5.0.2 and Elixir 1.19.5."

      assert out =~ "Move #{ctx.versions} to the image's runtime (or the digest back)"
    end

    test "when only the Elixir version differs", ctx do
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, "OTP=28.5.0.2\nELIXIR=1.19.7\n")

      assert {out, 1} = run(ctx, [ctx.versions, root])
      assert out =~ "which ships OTP 28.5.0.2 and Elixir 1.19.7, but"
    end

    test "when only the benchmark image drifted, as a Dependabot bump of /benchmark alone would", ctx do
      {root, bench} = root_and_bench!(ctx, @image_b)
      image_answers!(ctx, @a, @matching)
      image_answers!(ctx, @b, "OTP=29.0.1\nELIXIR=1.20.4\n")

      assert {out, 1} = run(ctx, [ctx.versions, root, bench])
      assert out =~ "#{root}: #{@image_a} ships OTP 28.5.0.2"
      assert out =~ "FAIL: #{bench} builds from #{@image_b}, which ships OTP 29.0.1 and Elixir 1.20.4"
    end

    test "after checking every image, not only up to the first failure", ctx do
      {root, bench} = root_and_bench!(ctx, @image_b)
      image_answers!(ctx, @a, "OTP=28.5.0.7\nELIXIR=1.19.5\n")
      image_answers!(ctx, @b, @matching)

      assert {out, 1} = run(ctx, [ctx.versions, root, bench])
      assert out =~ "FAIL: #{root} builds from"
      assert out =~ "#{bench}: #{@image_b} ships OTP 28.5.0.2"
    end
  end

  describe "fails when an image cannot be compared" do
    test "when a Dockerfile builds from no elixir image", ctx do
      file = dockerfile!(ctx, "Dockerfile", "FROM alpine:3.21\nFROM erlang:28-alpine\n")

      assert {out, 1} = run(ctx, [ctx.versions, file])
      assert out =~ "FAIL: #{file} has no FROM elixir stage to compare"
      assert docker_calls(ctx) == []
    end

    test "when the elixir image is not pinned by digest", ctx do
      file = dockerfile!(ctx, "Dockerfile", "FROM elixir:1.19-otp-28-alpine AS builder\n")

      assert {out, 1} = run(ctx, [ctx.versions, file])
      assert out =~ "FAIL: #{file} builds from elixir:1.19-otp-28-alpine, which is not pinned by digest"
      assert docker_calls(ctx) == []
    end

    test "when a Dockerfile does not exist", ctx do
      missing = Path.join(ctx.dir, "nope")
      assert {out, 1} = run(ctx, [ctx.versions, missing])
      assert out =~ "FAIL: #{missing} does not exist"
    end

    test "when the image prints no OTP or no Elixir line", ctx do
      {root, _bench} = root_and_bench!(ctx)

      for {output, key} <- [{"ELIXIR=1.19.5\n", "OTP"}, {"OTP=28.5.0.2\n", "ELIXIR"}, {"OTP=\nELIXIR=1.19.5\n", "OTP"}] do
        image_answers!(ctx, @a, output)
        assert {out, 1} = run(ctx, [ctx.versions, root]), inspect(output)
        assert out =~ "FAIL: #{@image_a} printed no single #{key}=<version> line; its output was:"
      end
    end

    test "when the image holds two OTP installations, which is ambiguous", ctx do
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, "OTP=28.5.0.2\nOTP=27.3\nELIXIR=1.19.5\n")

      assert {out, 1} = run(ctx, [ctx.versions, root])
      assert out =~ "printed no single OTP=<version> line"
    end

    test "naming the exit status when docker fails, matching output or not", ctx do
      {root, _bench} = root_and_bench!(ctx)
      image_answers!(ctx, @a, "manifest unknown\n" <> @matching, 125)

      assert {out, 1} = run(ctx, [ctx.versions, root])
      assert out =~ "FAIL: #{@image_a} (from #{root}) exited with status 125"
      assert out =~ "manifest unknown"
    end

    test "with the timeout status when the image never answers", ctx do
      {root, _bench} = root_and_bench!(ctx)
      File.write!(Path.join(ctx.stub_data, String.duplicate("a", 64) <> ".sleep"), "30")

      {elapsed_us, {out, status}} =
        :timer.tc(fn -> run(ctx, [ctx.versions, root], [{"RUNTIME_CHECK_TIMEOUT", "1"}]) end)

      assert status == 1
      assert out =~ "exited with status 124 (124 is the 1s timeout)"
      assert elapsed_us < 20_000_000
    end
  end

  describe "usage errors" do
    test "refuses fewer than two arguments, or an empty one", ctx do
      for args <- [[], [ctx.versions], ["", "Dockerfile"], [ctx.versions, ""]] do
        assert {out, 2} = run(ctx, args)
        assert out =~ "usage:"
      end
    end

    test "refuses a versions file that is missing or does not pin one erlang and one elixir", ctx do
      {root, _bench} = root_and_bench!(ctx)

      cases = [
        {"erlang 28.5.0.2\n", "must hold exactly one 'elixir <version>' line"},
        {"elixir 1.19.5-otp-28\n", "must hold exactly one 'erlang <version>' line"},
        {"erlang 28.5.0.2\nerlang 28.5.0.3\nelixir 1.19.5-otp-28\n", "exactly one 'erlang <version>' line"},
        {"# erlang 28.5.0.2\nelixir 1.19.5-otp-28\n", "exactly one 'erlang <version>' line"},
        {"erlang 28.5.0.2\nelixir 1.19.5\n", "pins elixir 1.19.5, which is not <version>-otp-28 for erlang 28.5.0.2"},
        {"erlang 28.5.0.2\nelixir 1.19.5-otp-27\n", "pins elixir 1.19.5-otp-27, which is not <version>-otp-28"}
      ]

      for {body, message} <- cases do
        File.write!(ctx.versions, body)
        assert {out, 2} = run(ctx, [ctx.versions, root]), inspect(body)
        assert out =~ message, inspect(body)
      end

      missing = Path.join(ctx.dir, "none")
      assert {out, 2} = run(ctx, [missing, root])
      assert out =~ "versions file #{missing} does not exist"
      assert docker_calls(ctx) == []
    end

    test "refuses a timeout that would mean no limit or is not a whole number of seconds", ctx do
      for bad <- ["0", "01", "1.5", "abc", "-1", "100000"] do
        assert {out, 2} = run(ctx, [ctx.versions, "Dockerfile"], [{"RUNTIME_CHECK_TIMEOUT", bad}]),
               "accepted #{inspect(bad)}"

        assert out =~ "RUNTIME_CHECK_TIMEOUT must be a whole number of seconds from 1 to 99999"
      end
    end

    test "refuses a timeout set but empty rather than taking the default", ctx do
      # System.cmd unsets a variable given as "", so bash sets it empty on the script's own command line.
      assert {out, 2} =
               System.cmd(
                 "bash",
                 ["-c", ~s(RUNTIME_CHECK_TIMEOUT= exec bash "$0" "$1" Dockerfile), @script, ctx.versions],
                 env: [{"PATH", "#{ctx.stub_bin}:#{System.get_env("PATH")}"}],
                 stderr_to_stdout: true
               )

      assert out =~
               "RUNTIME_CHECK_TIMEOUT must be a whole number of seconds from 1 to 99999 without leading zeros, got ''"
    end

    test "names the missing tool when coreutils timeout is not on PATH", ctx do
      # Only the stub bin: bash itself is resolved by System.cmd, and the script stops before any other tool.
      assert {out, 2} =
               System.cmd("bash", [@script, ctx.versions, "Dockerfile"],
                 env: [{"PATH", ctx.stub_bin}],
                 stderr_to_stdout: true
               )

      assert out =~ "this check requires coreutils timeout, which is not on PATH"
      assert docker_calls(ctx) == []
    end
  end

  describe "the workflows" do
    test "set up Erlang/OTP and Elixir only from .github/beam-versions" do
      for file <- workflow_files() do
        text = File.read!(file)
        steps = setup_beam_steps(text)

        # Every mention of the action is a step the split found, so a spelling it cannot see (a quoted
        # `uses:`, an `id:` written first) fails here instead of escaping the assertions below.
        assert length(steps) == length(Regex.scan(~r/erlef\/setup-beam@/, text)), Path.basename(file)

        for step <- steps do
          assert step =~ "version-file: .github/beam-versions", "#{Path.basename(file)}: #{step}"
          assert step =~ "version-type: strict", "#{Path.basename(file)}: #{step}"
          refute step =~ ~r/(otp|elixir)-version:/, "#{Path.basename(file)}: #{step}"
        end
      end

      # Guards the wildcard: finding no workflow, or none with the action, would pass every loop above.
      assert Enum.sum(Enum.map(workflow_files(), &length(setup_beam_steps(File.read!(&1))))) > 0
    end

    test "name a step id in the same job for every steps.<id>.outputs they read" do
      # An expression on a step id the job does not have evaluates to an empty string without an error, so a
      # cache key built from the toolchain would silently lose it.
      for file <- workflow_files(), {job, body} <- jobs(File.read!(file)) do
        for [id] <- Regex.scan(~r/steps\.([A-Za-z0-9_-]+)\.outputs/, body, capture: :all_but_first) do
          assert body =~ ~r/^\s*(- )?id: #{Regex.escape(id)}\s*$/m,
                 "#{Path.basename(file)} job #{job} reads steps.#{id}.outputs but has no step with id #{id}"
        end
      end
    end

    test "compare both Dockerfiles' base images in the Docker Build Test" do
      ci = File.read!(Path.join(@workflows, "ci.yml"))
      {_job, docker_job} = Enum.find(jobs(ci), fn {_job, body} -> body =~ "name: Docker Build Test" end)

      assert docker_job =~
               "run: scripts/check-image-runtime.sh .github/beam-versions Dockerfile benchmark/Dockerfile.loadtest"
    end

    test "pin an exact Erlang/OTP and an Elixir built for its OTP major in .github/beam-versions" do
      versions =
        for line <- String.split(File.read!(@versions_file), "\n"),
            not String.starts_with?(line, "#"),
            String.trim(line) != "",
            into: %{} do
          [app, version] = String.split(line)
          {app, version}
        end

      assert Enum.sort(Map.keys(versions)) == ["elixir", "erlang"]
      assert versions["erlang"] =~ ~r/^\d+(\.\d+){1,4}$/
      [otp_major | _] = String.split(versions["erlang"], ".")
      assert versions["elixir"] =~ ~r/^\d+\.\d+\.\d+-otp-#{otp_major}$/
    end
  end

  defp workflow_files, do: Path.wildcard(Path.join(@workflows, "*.{yml,yaml}"))

  # Each step that uses erlef/setup-beam: the text from one step's dash to the next.
  defp setup_beam_steps(workflow) do
    workflow
    |> String.split(~r/\n\s*- (?=[a-z-]+:)/)
    |> Enum.filter(&(&1 =~ "uses: erlef/setup-beam@"))
  end

  # {name, body} for each job: the text from a two-space-indented key under `jobs:` to the next one.
  defp jobs(workflow) do
    [_, body] = String.split(workflow, ~r/^jobs:[ \t]*$/m, parts: 2)

    ~r/^  ([A-Za-z0-9_-]+):[ \t]*$/m
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.drop_while(&(not Regex.match?(~r/^  [A-Za-z0-9_-]+:[ \t]*$/, &1)))
    |> Enum.chunk_every(2)
    |> Enum.map(fn [header, job] -> {String.trim(header) |> String.trim_trailing(":"), job} end)
  end
end
