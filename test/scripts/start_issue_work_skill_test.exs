defmodule StartIssueWorkSkillTest do
  # The start-issue-work skill is instructions, so these checks read what it ships and pin the facts that
  # went stale when the repository moved to malachi-hq: the owner, the board id and the field ids. A later
  # edit that brings back the old owner, or a board id that matches nothing, fails here rather than at the
  # next planning session, where an empty board query reads as "not on the board" and adds a duplicate.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @skill Path.join(@root, ".claude/skills/start-issue-work/SKILL.md")
  @command Path.join(@root, ".claude/commands/work.md")

  @repo "malachi-hq/malachi"
  @old_owner "HectorIFC"
  @board "PVT_kwDOFNzb_c4Bpo2F"
  @retired_board "PVT_kwHOAKYOJs4BP0nB"
  @status_field "PVTSSF_lADOFNzb_c4Bpo2FzhoDiu4"
  @size_field "PVTSSF_lADOFNzb_c4Bpo2FzhoDi3Q"

  setup_all do
    %{skill: File.read!(@skill)}
  end

  # Lines that run a gh command (issue, pr or api), not lines that merely mention the tool in prose.
  defp gh_command_lines(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/(^|[\s(\$])gh (issue|pr|api) /, &1))
  end

  test "never names the old owner, except in the one note that explains the move", %{skill: skill} do
    for line <- String.split(skill, "\n"), String.contains?(line, @old_owner) do
      assert String.contains?(line, "still say") and String.contains?(line, "is not the name"),
             "the skill names the old owner outside the explanatory note: #{String.trim(line)}"
    end
  end

  test "every gh command passes the repository explicitly", %{skill: skill} do
    lines = gh_command_lines(skill)
    assert lines != []

    for line <- lines do
      assert String.contains?(line, "--repo #{@repo}") or String.contains?(line, "repos/#{@repo}") or
               String.contains?(line, "owner:\"malachi-hq\""),
             "gh command without the malachi-hq repository: #{String.trim(line)}"
    end
  end

  test "the board id is the current project, and the retired id appears only in the sentence that retires it",
       %{skill: skill} do
    assert String.contains?(skill, @board)

    for line <- String.split(skill, "\n"), String.contains?(line, @retired_board) do
      assert String.contains?(line, "no longer"),
             "the retired board id is used outside the sentence that says it is retired: #{String.trim(line)}"
    end
  end

  test "the Status and Size field ids are the ones the board reports", %{skill: skill} do
    assert String.contains?(skill, @status_field)
    assert String.contains?(skill, @size_field)
  end

  test "each Status option id sits next to its own name, so two ids cannot be swapped unnoticed", %{skill: skill} do
    # Each pairing is written in the skill as it is read by a planner: the name, then its id in code ticks.
    assert skill =~ "Ready (`61e4505c`)"

    for {name, id} <- [
          {"Backlog", "f75ad846"},
          {"In progress", "47fc9ee4"},
          {"In review", "df73e18b"},
          {"Done", "98236657"}
        ] do
      assert Regex.match?(~r/#{Regex.escape(name)}\s+`#{id}`/, skill),
             "Status option #{name} must sit next to its id #{id}"
    end
  end

  test "the worktree port range names all six ports the script reserves, through +5" do
    skill = File.read!(@skill)
    assert skill =~ "`20000 + 10N + 5`"
    assert skill =~ "`MALACHI_CONSOLE_PORT`"
  end

  test "states that the board has no Priority field, so the P0 rule is not applied silently", %{skill: skill} do
    assert skill =~ ~r/Priority is not on this board/
    refute skill =~ "PVTSSF_lAHOAKYOJs4BP0nBzg-HsB0"
  end

  test "the planning prompt tells the session to use the repository and /usr/bin/git", %{skill: skill} do
    assert skill =~ ~r/Every `gh` call takes `--repo malachi-hq\/malachi`/
    assert skill =~ "/usr/bin/git"
  end

  test "the work command still points at the skill and the stop rules it relies on" do
    command = File.read!(@command)
    assert command =~ "`start-issue-work` skill"
    assert command =~ "scripts/worktree-env.sh"
  end

  test "the skill has no em dash, a repository rule" do
    skill = File.read!(@skill)
    # Written as an escape so this file does not carry the character it forbids.
    refute skill =~ "\u2014"
  end
end
