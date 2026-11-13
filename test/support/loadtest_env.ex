defmodule Malachi.Test.LoadtestEnv do
  @moduledoc """
  Keeps the load generator's login variables out of a test. `mix malachi.loadtest` reads `MALACHI_USER`,
  `MALACHI_PASS` and `MALACHI_TOKEN` from the environment (#180), so a value the shell running `mix test`
  happens to export would otherwise change who a test logs in as. Call `isolate/0` from a `setup` of a
  module that is not async: the variables are unset for the test and restored when it exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @vars ~w(MALACHI_USER MALACHI_PASS MALACHI_TOKEN)

  @doc "The variables `isolate/0` clears."
  def vars, do: @vars

  @doc "Unsets the login variables for the current test and restores them, set or unset, on exit."
  def isolate do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)
    :ok
  end
end
