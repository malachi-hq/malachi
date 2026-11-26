defmodule CookieLiteralsTest do
  # Every distribution cookie written into this repository is either taken from the environment or refused by a
  # clustered node (Malachi.Cluster.DistGuard.denylist/0, #385). A literal added to a compose file, a script, a
  # manifest or a doc without joining the denylist would be a cookie anyone can read that a cluster still accepts.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.DistGuard

  @root Path.expand("../..", __DIR__)

  # Where a cookie is set, in the forms this repository uses: a flag (shell and JSON-list forms), an Erlang argument,
  # an environment assignment, a Kubernetes Secret key and a shell default.
  @patterns [
    ~r/--cookie[ =]+"?([^"\s]+)/,
    ~r/"--cookie",\s*"([^"]*)"/,
    ~r/-setcookie\s+(\S+)/,
    ~r/RELEASE_COOKIE\s*[:=]\s*"?([^"\s]+)/,
    ~r/release-cookie:\s*"([^"]*)"/,
    ~r/\$\{[A-Z_]*COOKIE[A-Z_]*:-([^}]*)\}/
  ]

  # A value taken from somewhere else: the environment or a command, a template variable, or a placeholder in
  # prose and usage text.
  defp reference?(value) do
    String.starts_with?(value, ["$", "<", "{", "(", "#"]) or value in ["...", "\\"] or
      Regex.match?(~r/\A(?:Node\.get_cookie|String\.|cookie\b)/, value)
  end

  defp literals(text) do
    for pattern <- @patterns,
        [_, value] <- Regex.scan(pattern, text),
        value = String.trim(value, "'"),
        value != "",
        not reference?(value),
        do: value
  end

  defp tracked_files do
    {out, 0} = System.cmd("git", ["ls-files"], cd: @root)

    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&skipped?/1)
  end

  # lib/ sets no cookie; the denylist itself and these tests name the literals on purpose; binaries hold no text.
  defp skipped?(file) do
    String.starts_with?(file, ["lib/", "deps/", "_build/"]) or
      file in ["test/scripts/cookie_literals_test.exs", "test/malachi/cluster/dist_guard_test.exs"] or
      Path.extname(file) in ~w(.png .jpg .woff2 .pdf .ico .gz)
  end

  test "every cookie literal in the repository is one a clustered node refuses" do
    found =
      for file <- tracked_files(),
          {:ok, text} <- [File.read(Path.join(@root, file))],
          String.valid?(text),
          literal <- literals(text),
          literal not in DistGuard.denylist(),
          do: "#{file}: #{literal}"

    assert found == [], "cookie literals a cluster would accept:\n" <> Enum.join(found, "\n")
  end

  describe "the reader" do
    test "finds a literal in every form" do
      assert literals(~s(elixir --sname a --cookie lit1 -S mix)) == ["lit1"]
      assert literals(~s(entrypoint: ["elixir", "--cookie", "lit2"])) == ["lit2"]
      assert literals("## -setcookie lit3") == ["lit3"]
      assert literals("RELEASE_COOKIE: lit4\nRELEASE_COOKIE=lit5") == ["lit4", "lit5"]
      assert literals(~s(  release-cookie: "lit6")) == ["lit6"]
      assert literals("RELEASE_COOKIE: ${MALACHI_COOKIE:-lit7}") == ["lit7"]
    end

    test "passes over values taken from the environment, a template or a placeholder" do
      for text <- [
            ~s(--cookie "$MALACHI_COOKIE"),
            ~s(sh -c 'exec elixir --cookie "$$MALACHI_COOKIE"'),
            "RELEASE_COOKIE=${cookie}",
            "RELEASE_COOKIE: ${MALACHI_COOKIE:?set it}",
            "--cookie <cookie>",
            "--cookie ...",
            "--cookie (or $RELEASE_COOKIE)",
            "--cookie Node.get_cookie()"
          ] do
        assert literals(text) == [], text
      end
    end
  end
end
