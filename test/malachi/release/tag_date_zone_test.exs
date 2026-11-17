defmodule Malachi.Release.TagDateZoneTest do
  # Measurements.tag_date/2 dates a tag in UTC whatever zone the caller's process is in (#373). The suite's
  # runner is often in UTC already, which would hide a lost TZ=UTC0, so this sets another zone for the process,
  # which is global state: the module is not async.
  use ExUnit.Case, async: false

  alias Malachi.Release.Measurements

  @moduletag :tmp_dir

  test "a tag made at 02:30 UTC is that UTC day for a caller west of UTC", %{tmp_dir: repo} do
    git = fn args, env ->
      {_, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
          cd: repo,
          stderr_to_stdout: true,
          env: env
        )
    end

    date = [{"GIT_COMMITTER_DATE", "2026-11-17T02:30:00Z"}, {"GIT_AUTHOR_DATE", "2026-11-17T02:30:00Z"}]
    git.(["init", "-q", "-b", "main"], [])
    git.(["commit", "-q", "--allow-empty", "-m", "chore: bump version to 0.1.0"], date)
    git.(["tag", "-a", "v0.1.0", "-m", "v0.1.0"], date)

    previous = System.get_env("TZ")
    System.put_env("TZ", "America/Sao_Paulo")

    try do
      assert Measurements.tag_date(repo, "v0.1.0") == ~D[2026-11-17]
    after
      if previous, do: System.put_env("TZ", previous), else: System.delete_env("TZ")
    end
  end
end
