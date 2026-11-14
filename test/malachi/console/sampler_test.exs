defmodule Malachi.Console.SamplerTest do
  # async: false. The sampler and its table are the node's.
  use ExUnit.Case, async: false

  alias Malachi.Console.Sampler

  setup do
    Sampler.clear()
    :ok
  end

  # A read that counts its calls in an Agent and answers with the count.
  defp counting_read do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    read = fn -> {:ok, Agent.get_and_update(counter, &{&1 + 1, &1 + 1})} end
    {read, fn -> Agent.get(counter, & &1) end}
  end

  test "a sample younger than the interval is answered without reading again" do
    {read, calls} = counting_read()
    assert {:ok, %{value: 1, stale: false, sampled_at: at}} = Sampler.fetch(:young, read, interval_ms: 60_000)
    assert {:ok, %{value: 1, stale: false, sampled_at: ^at}} = Sampler.fetch(:young, read, interval_ms: 60_000)
    assert calls.() == 1
  end

  test "a sample older than the interval is taken again" do
    {read, calls} = counting_read()
    assert {:ok, %{value: 1}} = Sampler.fetch(:old, read, interval_ms: 0)
    assert {:ok, %{value: 2}} = Sampler.fetch(:old, read, interval_ms: 0)
    assert calls.() == 2
  end

  test "callers that ask at once share one read, however many they are" do
    parent = self()

    read = fn ->
      send(parent, :read_started)

      receive do
        :go -> {:ok, :shared}
      end
    end

    callers = for _n <- 1..20, do: Task.async(fn -> Sampler.fetch(:shared, read, interval_ms: 0) end)
    assert_receive :read_started
    # every caller is queued on the one read before it finishes
    Process.sleep(50)
    refute_received :read_started
    [{_key, %{task: %{pid: reader}}}] = :sys.get_state(Sampler).inflight |> Map.to_list()
    send(reader, :go)

    for caller <- callers, do: assert({:ok, %{value: :shared, stale: false}} = Task.await(caller))
  end

  test "a read that fails, raises or overruns answers with the previous sample, marked stale" do
    assert {:ok, %{value: :first}} = Sampler.fetch(:fallback, fn -> {:ok, :first} end)

    for failing <- [
          fn -> {:error, :down} end,
          fn -> raise "read failed" end,
          fn -> Process.sleep(:infinity) end
        ] do
      assert {:ok, %{value: :first, stale: true}} =
               Sampler.fetch(:fallback, failing, interval_ms: 0, timeout_ms: 100)
    end
  end

  test "a read that fails with no previous sample is unavailable, and a later one fills it" do
    assert Sampler.fetch(:empty, fn -> {:error, :down} end) == {:error, :unavailable}
    # tried again once the interval is up (0 here)
    assert {:ok, %{value: :late, stale: false}} = Sampler.fetch(:empty, fn -> {:ok, :late} end, interval_ms: 0)
  end

  test "a slow read of one key does not hold up another" do
    slow = Task.async(fn -> Sampler.fetch(:slow, fn -> Process.sleep(:infinity) end, timeout_ms: 500) end)
    Process.sleep(20)
    {micros, result} = :timer.tc(fn -> Sampler.fetch(:fast, fn -> {:ok, :fast} end) end)
    assert {:ok, %{value: :fast}} = result
    assert micros < 400_000
    assert Task.await(slow) == {:error, :unavailable}
  end

  test "a sampler that does not answer leaves the caller with the last sample, marked stale" do
    assert {:ok, %{value: :kept}} = Sampler.fetch(:suspended, fn -> {:ok, :kept} end)
    :ok = :sys.suspend(Sampler)

    try do
      assert {:ok, %{value: :kept, stale: true}} =
               Sampler.fetch(:suspended, fn -> {:ok, :new} end, interval_ms: 0, timeout_ms: 10)

      assert Sampler.fetch(:never_taken, fn -> {:ok, :new} end, timeout_ms: 10) == {:error, :unavailable}
    after
      :sys.resume(Sampler)
    end
  end

  describe "interval_ms/0" do
    setup do
      on_exit(fn -> Application.delete_env(:malachi, :console_sample_ms) end)
    end

    test "is the configured interval when it is a positive integer" do
      Application.put_env(:malachi, :console_sample_ms, 250)
      assert Sampler.interval_ms() == 250
    end

    test "is 1000 ms when unset, or set to 0, a negative number or not a number" do
      Application.delete_env(:malachi, :console_sample_ms)
      assert Sampler.interval_ms() == 1_000

      for invalid <- [0, -1, "500", nil, 1.5] do
        Application.put_env(:malachi, :console_sample_ms, invalid)
        assert Sampler.interval_ms() == 1_000, inspect(invalid)
      end
    end
  end

  test "a read that failed is not tried again before an interval has passed" do
    {read, calls} = counting_read()
    assert {:ok, %{value: 1}} = Sampler.fetch(:retry, read, interval_ms: 50)
    Process.sleep(60)

    # the sample is older than the interval, so this read is tried, and fails
    {failing_read, failing_calls} = counting_failure()
    assert {:ok, %{value: 1, stale: true}} = Sampler.fetch(:retry, failing_read, interval_ms: 50)
    assert failing_calls.() == 1

    # within the interval after the failure, every caller gets the last sample without a new read
    for _caller <- 1..5 do
      assert {:ok, %{value: 1, stale: true}} = Sampler.fetch(:retry, failing_read, interval_ms: 50)
    end

    assert failing_calls.() == 1
    assert calls.() == 1

    # once it is up it is tried again, and a read that works clears the failure
    Process.sleep(60)
    assert {:ok, %{value: 2, stale: false}} = Sampler.fetch(:retry, read, interval_ms: 50)
    assert {:ok, %{value: 2, stale: false}} = Sampler.fetch(:retry, read, interval_ms: 60_000)
  end

  for {kind, read} <- [
        raises: quote(do: fn -> raise "read failed" end),
        overruns: quote(do: fn -> Process.sleep(:infinity) end)
      ] do
    test "a read that #{kind} is not tried again before an interval has passed either" do
      {read, calls} = counting(unquote(read))
      assert {:ok, %{value: :kept}} = Sampler.fetch(unquote(kind), fn -> {:ok, :kept} end, interval_ms: 50)
      Process.sleep(60)

      # the sample is older than the interval: this read is tried, and fails
      assert {:ok, %{value: :kept, stale: true}} = Sampler.fetch(unquote(kind), read, interval_ms: 50, timeout_ms: 100)
      assert calls.() == 1

      for _caller <- 1..5 do
        assert {:ok, %{value: :kept, stale: true}} =
                 Sampler.fetch(unquote(kind), read, interval_ms: 50, timeout_ms: 100)
      end

      assert calls.() == 1
    end
  end

  # `failing` with a count of how many times it was started.
  defp counting(failing) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    read = fn ->
      Agent.update(counter, &(&1 + 1))
      failing.()
    end

    {read, fn -> Agent.get(counter, & &1) end}
  end

  test "a young sample the caller says no longer answers its question is read again, and one it accepts is not" do
    {read, calls} = counting_read()
    assert {:ok, %{value: 1}} = Sampler.fetch(:asked, read, interval_ms: 60_000)

    assert {:ok, %{value: 1}} = Sampler.fetch(:asked, read, interval_ms: 60_000, current?: &(&1 == 1))
    assert calls.() == 1

    assert {:ok, %{value: 2, stale: false}} = Sampler.fetch(:asked, read, interval_ms: 60_000, current?: &(&1 == 2))
    assert calls.() == 2
  end

  test "a sample the caller rejects is not read again soon after a read that failed" do
    assert {:ok, %{value: :old}} = Sampler.fetch(:rejected, fn -> {:ok, :old} end, interval_ms: 60_000)
    {failing, calls} = counting(fn -> {:error, :down} end)
    reject = [interval_ms: 60_000, current?: fn _value -> false end]

    for _caller <- 1..5 do
      assert {:ok, %{value: :old, stale: true}} = Sampler.fetch(:rejected, failing, reject)
    end

    assert calls.() == 1
  end

  test "a key whose first read failed is unavailable until the interval is up, with no new read" do
    {failing_read, failing_calls} = counting_failure()
    assert Sampler.fetch(:never, failing_read, interval_ms: 60_000) == {:error, :unavailable}
    assert Sampler.fetch(:never, failing_read, interval_ms: 60_000) == {:error, :unavailable}
    assert failing_calls.() == 1
  end

  defp counting_failure do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    read = fn ->
      Agent.update(counter, &(&1 + 1))
      {:error, :down}
    end

    {read, fn -> Agent.get(counter, & &1) end}
  end
end
