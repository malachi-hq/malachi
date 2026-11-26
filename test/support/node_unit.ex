defmodule Malachi.Test.NodeUnit do
  @moduledoc """
  Runs a file of Node unit tests (`node --test`) and asserts that all of the tests its caller expects ran and passed.

  The reporter is named, TAP, rather than left to the Node version: Node 23 and later print the spec reporter by
  default, and a check that read the default output failed under the runner's Node while it passed under the
  Node 22 the test job installs (#390). The exit status alone is not enough either: a file that declares no test
  exits 0 and is reported as one passing test named after the file, so the caller states how many tests the file
  holds, and a test lost from it fails here too.
  """

  import ExUnit.Assertions

  @doc """
  Runs `file` under `node` with the TAP reporter and asserts it exited 0 and reported exactly `tests:` tests,
  all of them passing. The failure message carries Node's output.
  """
  @spec assert_pass(String.t(), Path.t(), tests: pos_integer()) :: :ok
  def assert_pass(node, file, tests: expected) when is_integer(expected) and expected > 0 do
    {output, status} = System.cmd(node, ["--test", "--test-reporter=tap", file], stderr_to_stdout: true)

    assert status == 0, "node --test #{file} exited with status #{status}:\n#{output}"

    reported = counts(output)

    assert reported == [tests: expected, pass: expected, fail: 0],
           "node --test #{file} reported #{summary(reported)}, expected #{expected} tests, all passing:\n#{output}"

    :ok
  end

  # The counts that close the TAP summary (`# tests 3`, `# pass 3`, `# fail 0`). A count it did not print reads as nil,
  # so output from another reporter fails the comparison instead of passing it.
  defp counts(output) do
    for key <- [:tests, :pass, :fail] do
      case Regex.run(~r/^# #{key} (\d+)$/m, output, capture: :all_but_first) do
        [count] -> {key, String.to_integer(count)}
        nil -> {key, nil}
      end
    end
  end

  defp summary(reported), do: Enum.map_join(reported, " ", fn {key, count} -> "#{key}=#{inspect(count)}" end)
end
