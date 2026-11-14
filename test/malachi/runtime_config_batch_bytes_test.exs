defmodule Malachi.RuntimeConfigBatchBytesTest do
  # config/runtime.exs refuses an inflate setting above the ceiling a stored batch frame is judged by
  # (Malachi.Log.BatchFrame.max_stored_inflated/0), so the node never accepts a batch the disk would read as
  # damage. Evaluated for real: the environment variable is process-global, so this module is not async.
  use ExUnit.Case, async: false

  alias Malachi.Log.BatchFrame

  @var "MALACHI_MAX_INFLATED_BATCH_BYTES"
  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    previous = System.get_env(@var)
    on_exit(fn -> if previous, do: System.put_env(@var, previous), else: System.delete_env(@var) end)
  end

  defp read_with(value) do
    System.put_env(@var, value)
    Config.Reader.read!(@runtime, env: :test, target: :host)
  end

  test "the ceiling itself is accepted" do
    config = read_with(Integer.to_string(BatchFrame.max_stored_inflated()))
    assert config[:malachi][:max_inflated_batch_bytes] == BatchFrame.max_stored_inflated()
  end

  test "one byte above the ceiling stops the boot" do
    assert_raise RuntimeError, ~r/MALACHI_MAX_INFLATED_BATCH_BYTES 268435457 is above 268435456/, fn ->
      read_with(Integer.to_string(BatchFrame.max_stored_inflated() + 1))
    end
  end

  test "a lower setting is accepted, since lowering it later never makes stored batches unreadable" do
    assert read_with("1024")[:malachi][:max_inflated_batch_bytes] == 1024
  end
end
