defmodule Malachi.Console.Sampler do
  @moduledoc """
  Where the console's reads of costly or hot state are taken, so their cost does not grow with the number
  of operators watching.

  Some reads the console needs are calls into processes that serve clients or run consensus: the broker's
  merged metadata (`Malachi.LogBroker`), the scrubber, the membership's gossip loop, a consistent query to
  a Raft leader. Asked once per request, every open tab would tax them once per refresh, hardest during an
  incident when the most people are watching (section 10.5 of `docs/design/operator-interfaces.md`).

  A read here is named by a key and taken by a function. `fetch/3` returns the last sample of that key
  while it is younger than the sampling interval (`MALACHI_CONSOLE_SAMPLE_MS`, 1000 ms by default), from
  an ETS table and without a message to anyone. An older or missing sample is taken again, once, however
  many callers ask for it meanwhile: the first one starts it and the others wait for the same answer. So
  each key costs at most one read per interval, nothing at all while nobody looks, and the first request
  after a quiet period pays for one fresh read.

  A read runs in a task of its own, bounded by the caller's timeout, so one slow key (the scrubber behind a
  segment scan) never holds up another. A read that fails, raises or overruns answers with the previous
  sample, marked stale, when there is one, and `{:error, :unavailable}` when there is none; and the next is
  not tried before an interval has passed, so a failing read costs no more than a working one. Every answer
  carries the time its sample was taken, which the API returns as `sampled_at`, so a client can tell how
  old what it shows is.

  Like NorthGuard's Conductor, which answers its clients' metadata reads from its own cache, the console
  reads a copy rather than the processes that own the state.
  """

  use GenServer

  @table :malachi_console_samples
  @default_interval_ms 1_000
  @default_timeout_ms 2_000

  @typedoc "A sample: the value, when it was taken (Unix milliseconds), and whether it is older than asked for."
  @type sample :: %{value: term(), sampled_at: integer(), stale: boolean()}

  @doc "Starts the sampler, which owns the sample table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The sample of `key`, taken by `read` (a zero arity function that returns `{:ok, value}` or
  `{:error, reason}`) when the last one is older than the interval. Options: `:timeout_ms`, how long a fresh
  read may take (#{@default_timeout_ms} ms by default), `:interval_ms`, in place of the configured one, and
  `:current?`, a function of a sample's value that says whether it still answers the caller's question (a
  value built from inputs the caller has since replaced does not): a sample it rejects is old, however young,
  and is read again on the same terms as any old sample, the failure latch included.
  """
  @spec fetch(term(), (-> {:ok, term()} | {:error, term()}), keyword()) :: {:ok, sample()} | {:error, :unavailable}
  def fetch(key, read, opts \\ []) when is_function(read, 0) do
    interval = Keyword.get_lazy(opts, :interval_ms, &interval_ms/0)
    current? = Keyword.get(opts, :current?, fn _value -> true end)
    now = now()

    case lookup(key) do
      {{value, sampled_at}, failed_at} ->
        cond do
          now - sampled_at < interval and current?.(value) ->
            {:ok, %{value: value, sampled_at: sampled_at, stale: false}}

          recently_failed?(failed_at, now, interval) ->
            current(key, true)

          true ->
            refresh(key, read, opts)
        end

      {nil, failed_at} ->
        if recently_failed?(failed_at, now, interval), do: current(key, true), else: refresh(key, read, opts)

      nil ->
        refresh(key, read, opts)
    end
  end

  # A read failed less than an interval ago: the next is not tried before the interval is up, so a failing
  # read costs one per interval like a working one, not one per caller.
  defp recently_failed?(failed_at, now, interval), do: is_integer(failed_at) and now - failed_at < interval

  @doc """
  The sampling interval: `MALACHI_CONSOLE_SAMPLE_MS` (`:console_sample_ms`), 1000 ms by default. A value
  that is not a positive integer is the default: 0 would read on every call and a negative interval cannot
  be scheduled (`config/runtime.exs` logs such a value when the node starts).
  """
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    case Application.get_env(:malachi, :console_sample_ms, @default_interval_ms) do
      interval when is_integer(interval) and interval > 0 -> interval
      _invalid -> @default_interval_ms
    end
  end

  @doc "Forgets every sample (a test starts from nothing)."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  defp refresh(key, read, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # the sampler answers after the read's own bound, so the call waits a little longer than it
    case GenServer.call(__MODULE__, {:refresh, key, read, timeout}, timeout + 1_000) do
      :ok -> current(key, false)
      :failed -> current(key, true)
    end
  catch
    :exit, _sampler_unavailable -> current(key, true)
  end

  defp current(key, stale?) do
    case lookup(key) do
      {{value, sampled_at}, _failed_at} -> {:ok, %{value: value, sampled_at: sampled_at, stale: stale?}}
      _none -> {:error, :unavailable}
    end
  end

  # A key's row: its last sample as `{value, sampled_at}` (nil before the first read that worked), and when
  # a read last failed (nil once one works again).
  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, sample, failed_at}] -> {sample, failed_at}
      [] -> nil
    end
  rescue
    # the table goes with the sampler, and a read between a crash and the restart finds none
    ArgumentError -> nil
  end

  defp now, do: System.system_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{inflight: %{}}}
  end

  @impl true
  def handle_call({:refresh, key, read, timeout}, from, state) do
    case Map.fetch(state.inflight, key) do
      {:ok, %{waiters: waiters} = inflight} ->
        {:noreply, put_in(state.inflight[key], %{inflight | waiters: [from | waiters]})}

      :error ->
        task = Task.Supervisor.async_nolink(Malachi.Console.SamplerTasks, fn -> run(read) end)
        timer = Process.send_after(self(), {:overrun, task.ref}, timeout)
        {:noreply, put_in(state.inflight[key], %{task: task, timer: timer, waiters: [from]})}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, value} -> finish(state, ref, fn key -> :ets.insert(@table, {key, {value, now()}, nil}) end, :ok)
      _failed -> finish(state, ref, &failed/1, :failed)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: finish(state, ref, &failed/1, :failed)

  def handle_info({:overrun, ref}, state) do
    case find(state, ref) do
      {_key, %{task: task}} ->
        Task.shutdown(task, :brutal_kill)
        finish(state, ref, &failed/1, :failed)

      nil ->
        {:noreply, state}
    end
  end

  defp finish(state, ref, store, reply) do
    case find(state, ref) do
      {key, %{timer: timer, waiters: waiters}} ->
        Process.cancel_timer(timer)
        store.(key)
        Enum.each(waiters, &GenServer.reply(&1, reply))
        {:noreply, %{state | inflight: Map.delete(state.inflight, key)}}

      nil ->
        {:noreply, state}
    end
  end

  # A failed read keeps the last sample and remembers when it failed.
  defp failed(key) do
    sample =
      case :ets.lookup(@table, key) do
        [{^key, sample, _failed_at}] -> sample
        [] -> nil
      end

    :ets.insert(@table, {key, sample, now()})
  end

  defp find(state, ref), do: Enum.find(state.inflight, fn {_key, %{task: task}} -> task.ref == ref end)

  defp run(read) do
    case read.() do
      {:ok, _value} = ok -> ok
      _error -> :error
    end
  end
end
