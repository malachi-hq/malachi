defmodule ReleaseCommunicationRoutineTest do
  # The routine per release lives in the checklist issue's template, which the release workflow opens, and in
  # the playbook a reader follows (#373). The template is its source; this keeps the two lists identical, so a
  # step added or reworded in one place fails here until the other says the same.
  use ExUnit.Case, async: true

  @template Path.expand("../../.github/ISSUE_TEMPLATE/release-communication.md", __DIR__)
  @playbook Path.expand("../../docs/guides/release-communication.md", __DIR__)

  # The list items of a `## <heading>` section, without their marker (`- [ ] ` or `1. `).
  defp items(path, heading) do
    [_, section] = path |> File.read!() |> String.split("## #{heading}\n", parts: 2)
    section = section |> String.split(~r/^## /m, parts: 2) |> hd() |> String.split(~r/^### /m, parts: 2) |> hd()

    for [_, item] <- Regex.scan(~r/^(?:- \[ \] |\d+\. )(.+)$/m, section), do: item
  end

  test "the playbook's routine is the template's, step for step" do
    template = items(@template, "Routine per release")
    assert length(template) == 4
    assert items(@playbook, "Routine per release") == template
  end

  test "the template's version placeholder is the one the workflow's script fills" do
    text = File.read!(@template)
    assert text =~ "title: Release vX.Y.Z communication"
    assert text =~ "`mix malachi.release.post vX.Y.Z`"
    assert File.read!(Path.expand("../../scripts/release-checklist-issue.sh", __DIR__)) =~ ~S|gsub(/vX\.Y\.Z/, tag)|
  end

  test "the template links the playbook where the site publishes it" do
    assert File.read!(@template) =~ "https://malachi-hq.github.io/malachi/release-communication.html"
    assert File.read!(Path.expand("../../mix.exs", __DIR__)) =~ ~s("docs/guides/release-communication.md")
  end
end
