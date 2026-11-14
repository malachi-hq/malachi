defmodule Malachi.Docs.PurgeWordingTest do
  @moduledoc """
  A purge is a logical purge, never erasure (#308): the records stay on disk until their segment expires.
  Every place the feature is documented must say "logical purge", and the word erasure (or erase) may
  appear there only to deny it, so a sentence that promises more than the code does cannot creep in
  unnoticed. Widening the allow-list is a decision, not a fix for a failing test.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Malachi.Purge, as: PurgeTask

  # The only phrases in which the word may appear: each one denies it.
  @denials ["is not erasure", "not erasure", "does not erase"]

  @guides ["docs/guides/purging-a-topic.md", "docs/guides/data-subject-requests.md"]
  @modules [Malachi.Purge, Malachi.Purge.Request, PurgeTask]

  @doc false
  # The violations in `text`: a missing "logical purge", and each use of erase or erasure outside a denial.
  @spec violations(String.t()) :: [String.t()]
  def violations(text) do
    missing = if text =~ ~r/logical purge/i, do: [], else: ["does not say \"logical purge\""]

    without_denials = Enum.reduce(@denials, text, &String.replace(&2, ~r/#{Regex.escape(&1)}/i, ""))

    claims =
      ~r/\b\w*eras(?:e|es|ed|ing|ure|ures)\b/i
      |> Regex.scan(without_denials)
      |> Enum.map(fn [word] -> "says #{inspect(word)} outside a denial" end)

    missing ++ claims
  end

  describe "the checker (non-vacuity)" do
    test "a denial passes" do
      assert violations("A logical purge. This is not erasure.") == []
      assert violations("A logical purge, not erasure, and it does not erase anything.") == []
      assert violations("A LOGICAL purge. This Is Not Erasure.") == []
    end

    test "a promise of erasure fails" do
      assert violations("A logical purge guarantees erasure.") == [~s(says "erasure" outside a denial)]
      assert violations("A logical purge erases the record.") == [~s(says "erases" outside a denial)]
      assert violations("A logical purge; records are erased.") == [~s(says "erased" outside a denial)]
      assert violations("Logical purge. Not only erasure but more.") == [~s(says "erasure" outside a denial)]
    end

    test "a text without \"logical purge\" fails" do
      assert violations("A purge. This is not erasure.") == [~s(does not say "logical purge")]
    end

    test "unrelated words that merely contain the letters do not count" do
      assert violations("A logical purge. Rasters and phrases.") == []
    end
  end

  for path <- @guides do
    test "#{path} says logical purge and never promises erasure" do
      assert violations(File.read!(unquote(path))) == []
    end
  end

  for module <- @modules do
    test "the moduledoc of #{inspect(module)} says logical purge and never promises erasure" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} = Code.fetch_docs(unquote(module))
      assert violations(moduledoc) == []
    end
  end

  test "what the mix task prints after a purge says logical purge and never promises erasure" do
    moves = %{{"t", 0} => {0, 4}}
    call = fn _module, _fun, _args -> {:ok, {:ok, moves}} end

    for opts <- [[group: "g"], [group: "g", request: "DSR-1", reason: "LGPD art. 18 request"]] do
      assert {:ok, message} = PurgeTask.execute(["t"], opts, call)
      assert violations(message) == []
    end
  end
end
