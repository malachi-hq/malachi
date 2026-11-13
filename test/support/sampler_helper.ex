defmodule Malachi.Test.SamplerHelper do
  @moduledoc """
  Seeds `Malachi.Console.Sampler` with a value of the test's own, for the console's route tests.

  A fetch made while a real read of the same key is in flight joins that read, and the value it stores is
  the real one, not the test's: something else on the node (the stream hub sampling for an open stream, a
  route another test called) may be reading the key at that moment. So the seed checks what was stored and
  tries again, a bounded number of times, until it is the test's.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Malachi.Console.Sampler

  @attempts 50
  @pause_ms 20

  @doc "Stores `value` as the sample of `key`, or fails the test if it never sticks."
  @spec seed!(term(), term()) :: :ok
  def seed!(key, value), do: seed!(key, value, @attempts)

  defp seed!(key, value, 0), do: flunk("could not seed the sample of #{inspect(key)} with #{inspect(value)}")

  defp seed!(key, value, attempts) do
    case Sampler.fetch(key, fn -> {:ok, value} end, interval_ms: 0) do
      {:ok, %{value: ^value}} ->
        :ok

      _another_read_won ->
        Process.sleep(@pause_ms)
        seed!(key, value, attempts - 1)
    end
  end

  @doc """
  Seeds the failure latch sample (`Malachi.Console.Samples.failed/0`) with `failed`, built from the
  metadata sample already seeded, as the real read records it.
  """
  @spec seed_failed!(Enumerable.t()) :: :ok
  def seed_failed!(failed) do
    {:ok, %{sampled_at: basis}} = Sampler.fetch(:metadata, fn -> {:error, :not_seeded} end, interval_ms: 600_000)
    seed!(:failed, {MapSet.new(failed), basis})
  end
end
