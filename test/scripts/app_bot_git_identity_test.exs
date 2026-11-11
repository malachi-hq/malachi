defmodule AppBotGitIdentityTest do
  # scripts/app-bot-git-identity.sh names the App that pushed a commit to main. It runs here against a real git
  # repository with gh replaced by a stub on PATH, so each case controls what the user lookup returns.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/app-bot-git-identity.sh", __DIR__)

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    {_, 0} = System.cmd("git", ["init", "--quiet", repo])

    # The stub prints FAKE_GH_OUT and exits with FAKE_GH_RC, and records its arguments.
    File.write!(Path.join(bin, "gh"), """
    #!/usr/bin/env bash
    printf '%s\\n' "$*" > "#{dir}/gh.args"
    printf '%s\\n' "${FAKE_GH_OUT:-}"
    exit "${FAKE_GH_RC:-0}"
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)
    %{dir: dir, repo: repo, path: "#{bin}:#{System.get_env("PATH")}"}
  end

  defp run(ctx, args, env) do
    System.cmd("bash", [@script | args],
      cd: ctx.repo,
      env: [{"PATH", ctx.path}, {"GIT_CONFIG_NOSYSTEM", "1"} | env],
      stderr_to_stdout: true
    )
  end

  defp config(ctx, key) do
    case System.cmd("git", ["config", "--local", "--get", key], cd: ctx.repo) do
      {value, 0} -> String.trim(value)
      {_, _} -> nil
    end
  end

  test "sets the bot user's name and noreply address from the looked-up id", ctx do
    assert {out, 0} = run(ctx, ["malachi-release"], [{"FAKE_GH_OUT", "245678901"}])
    assert config(ctx, "user.name") == "malachi-release[bot]"
    assert config(ctx, "user.email") == "245678901+malachi-release[bot]@users.noreply.github.com"
    assert out =~ "git identity: malachi-release[bot]"
    assert File.read!(Path.join(ctx.dir, "gh.args")) =~ "api /users/malachi-release%5Bbot%5D --jq .id"
  end

  for slug <- ["", "Malachi", "bad slug", "a;b", "x$(id)"] do
    test "refuses #{inspect(slug)} as a slug, before any lookup, and writes no identity", ctx do
      assert {out, 2} = run(ctx, [unquote(slug)], [{"FAKE_GH_OUT", "1"}])
      assert out =~ "not a GitHub App slug"
      refute File.exists?(Path.join(ctx.dir, "gh.args"))
      assert config(ctx, "user.name") == nil
    end
  end

  test "refuses no argument at all", ctx do
    assert {_, 2} = run(ctx, [], [])
  end

  for out <- ["", "null", "not-found", "12a"] do
    test "refuses a lookup that returned #{inspect(out)} instead of an id, and writes no identity", ctx do
      assert {msg, 1} = run(ctx, ["malachi-release"], [{"FAKE_GH_OUT", unquote(out)}])
      assert msg =~ "no bot user id"
      assert config(ctx, "user.email") == nil
    end
  end

  test "fails when the lookup itself fails, and writes no identity", ctx do
    assert {_, rc} = run(ctx, ["malachi-release"], [{"FAKE_GH_OUT", "HTTP 404"}, {"FAKE_GH_RC", "1"}])
    assert rc != 0
    assert config(ctx, "user.name") == nil
  end
end
