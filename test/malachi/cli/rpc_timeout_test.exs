defmodule Malachi.CLI.RpcTimeoutTest do
  # Calls the test VM itself over distribution, as the mix task tests do.
  use ExUnit.Case, async: true

  alias Malachi.CLI.Rpc

  test "rpc/2 gives up after its own timeout, and a faster call answers" do
    assert Rpc.rpc(node(), 100).(Process, :sleep, [1_000]) == {:error, :timeout}
    assert Rpc.rpc(node(), 2_000).(Process, :sleep, [50]) == {:ok, :ok}
  end

  test "rpc/1 keeps the 5 s default" do
    assert Rpc.rpc(node()).(Kernel, :+, [1, 2]) == {:ok, 3}
  end
end
