defmodule DockerfileStaticAssetsTest do
  # Malachi.Dashboard.Assets reads priv/static/dashboard while it compiles (#38). An image that runs
  # `mix compile` before copying priv/static fails to build, and benchmark/Dockerfile.loadtest is the image
  # every drill and cluster benchmark runs its brokers on, so a missed COPY there broke them all while the
  # release image still built. Every Dockerfile that compiles Malachi is checked here, without Docker.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @dockerfiles ["Dockerfile", "benchmark/Dockerfile.loadtest"]

  for dockerfile <- @dockerfiles do
    test "#{dockerfile} copies priv/static, and only that part of priv, before it compiles" do
      lines = @root |> Path.join(unquote(dockerfile)) |> File.read!() |> String.split("\n")

      copy = Enum.find_index(lines, &(String.trim(&1) == "COPY priv/static priv/static"))
      compile = Enum.find_index(lines, &(&1 =~ ~r/^RUN .*\bmix compile\b/))

      assert compile, "#{unquote(dockerfile)} has no RUN mix compile"
      assert copy, "#{unquote(dockerfile)} never copies priv/static"
      assert copy < compile, "#{unquote(dockerfile)} copies priv/static after mix compile"
      refute Enum.any?(lines, &(&1 =~ ~r/^COPY\s+priv\/?\s/)), "#{unquote(dockerfile)} copies priv as a whole"
    end
  end

  test "the list covers every Dockerfile in the repository that compiles Malachi" do
    # The tracked files only: deps, builds and test scratch under tmp/ carry Dockerfiles that are not ours.
    {tracked, 0} = System.cmd("git", ["ls-files", "--", "Dockerfile*", "**/Dockerfile*"], cd: @root)

    compiling =
      for path <- String.split(tracked, "\n", trim: true),
          File.read!(Path.join(@root, path)) =~ ~r/^RUN .*\bmix compile\b/m,
          do: path

    assert Enum.sort(compiling) == Enum.sort(@dockerfiles)
  end
end
