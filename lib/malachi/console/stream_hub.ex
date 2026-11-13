defmodule Malachi.Console.StreamHub do
  @moduledoc """
  The one sampler behind every open `/api/v1/stream` on this node (section 10.5 of
  `docs/design/operator-interfaces.md`): it takes the overview once per interval, whatever the number of
  streams open, turns it into a delta against the previous one, numbers it, keeps the recent ones in a
  bounded ring, and sends it to every subscriber. Today's dashboard stream calls into the broker once per
  connection per second instead, which taxes the data plane hardest during an incident.

  ## What the overview is

  The system series `Malachi.Console.Reads.history_series/0` serves, at their latest value, and every
  topic's summary as `GET /api/v1/topics` renders it. A delta names the series whose value changed, the
  topics that changed or appeared (each in full) and the topics that went away. A tick that changed nothing
  sends nothing.

  ## Event ids and resuming

  Every event has an id, `<epoch>.<sequence>`: the sequence counts this hub's events, and the epoch is a
  random name the hub takes when it starts, so an id from before a restart, or from another node, is never
  mistaken for one of this hub's. A client that reconnects with the id of the last event it saw
  (`subscribe/1`) gets every event after it while they are still in the ring, and the stream goes on with
  nothing skipped or repeated. Otherwise it gets a `gap` event, then a `snapshot` of the whole overview to
  resynchronise from:

    * `expired`: the id is older than the ring; `dropped` is how many events were lost;
    * `unknown`: the id is not this hub's (another node, a restart, or not an id at all); `dropped` is
      `null`, since nothing says how many were missed.

  A client with no id starts from a `snapshot`, whose id is the sequence it is current as of.

  ## Idle

  The hub samples only while some stream is open. When the first one subscribes after a quiet period, it
  samples at once, so a client resuming across the quiet period gets what changed during it as a delta
  rather than a stale replay. A sample that fails sends one `error` event (the translation key of the
  problem, as a problem body would carry it), and the next sample that works resumes the deltas.
  """

  use GenServer

  alias Malachi.Console.Reads
  alias Malachi.Console.Sampler
  alias Malachi.Console.Samples
  alias Malachi.Console.TopicsView

  @default_ring_size 300

  @typedoc "An event: its id, its kind (`snapshot`, `overview`, `gap` or `error`) and its JSON data."
  @type event :: %{id: String.t(), event: String.t(), data: map()}

  @doc "Starts the hub, registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Subscribes the calling process, which then receives `{:console_stream_event, event}` for every event
  after the ones returned here, in order. `last_event_id` is the id of the last event the client saw, or
  nil. Returns the events to send first: a replay, or a `gap` and a `snapshot`, or a `snapshot`. Calling
  it again resubscribes from a new position, which is how a subscriber that fell behind catches up.
  """
  @spec subscribe(String.t() | nil, GenServer.server()) :: [event()]
  def subscribe(last_event_id, hub \\ __MODULE__), do: GenServer.call(hub, {:subscribe, last_event_id})

  @impl true
  def init(opts) do
    state = %{
      epoch: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false),
      sequence: 0,
      ring: :queue.new(),
      ring_size: Keyword.get_lazy(opts, :ring_size, fn -> setting(:console_stream_ring_size, @default_ring_size) end),
      interval_ms: Keyword.get_lazy(opts, :interval_ms, &Sampler.interval_ms/0),
      read: Keyword.get(opts, :read, &read_overview/0),
      overview: nil,
      failing: false,
      subscribers: %{},
      timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, last_event_id}, {pid, _tag}, state) do
    # a hub that was idle samples before answering, so what changed while nobody looked is a delta
    state = if state.subscribers == %{}, do: state |> sample() |> schedule(), else: state
    state = watch(state, pid)
    {:reply, catch_up(state, last_event_id), state}
  end

  @impl true
  def handle_info(:tick, %{subscribers: subscribers} = state) when map_size(subscribers) == 0,
    do: {:noreply, %{state | timer: nil}}

  def handle_info(:tick, state), do: {:noreply, state |> sample() |> schedule()}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  defp watch(state, pid) do
    if Map.has_key?(state.subscribers, pid),
      do: state,
      else: %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
  end

  # One tick pending at a time: a sample taken out of turn (a subscriber arriving) restarts the interval.
  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, state.interval_ms)}
  end

  # --- sampling ---

  defp sample(state) do
    :telemetry.execute([:malachi, :console, :stream, :sample], %{subscribers: map_size(state.subscribers)}, %{})

    case state.read.() do
      {:ok, overview} ->
        delta = if state.overview, do: delta(state.overview, overview), else: :unchanged
        state = %{state | overview: overview, failing: false}
        if delta == :unchanged, do: state, else: publish(state, "overview", delta)

      {:error, _reason} when state.failing ->
        state

      {:error, _reason} ->
        publish(%{state | failing: true}, "error", %{"type" => "errors.http.unavailable"})
    end
  end

  defp publish(state, kind, data) do
    sequence = state.sequence + 1
    event = %{id: id(state.epoch, sequence), event: kind, data: data}
    ring = :queue.in({sequence, event}, state.ring)
    ring = if :queue.len(ring) > state.ring_size, do: :queue.drop(ring), else: ring
    for pid <- Map.keys(state.subscribers), do: send(pid, {:console_stream_event, event})
    %{state | sequence: sequence, ring: ring}
  end

  @doc false
  # The overview the stream carries: the latest system series and every topic's summary, from this node's
  # samples. Public so a test can build one the same way.
  @spec read_overview() :: {:ok, map()} | {:error, term()}
  def read_overview do
    case Samples.metadata() do
      {:error, :unavailable} ->
        {:error, :metadata_unavailable}

      sampled ->
        topics =
          case sampled do
            {:ok, %{value: metadata}} -> TopicsView.topics(metadata)
            :none -> []
          end

        %{series: series} = Reads.metrics_history(5, Reads.history_series())

        {:ok,
         %{
           "system" => Map.new(series, fn {name, values} -> {name, List.last(values)} end),
           "topics" => Map.new(topics, &{&1.name, TopicsView.render_topic(&1)})
         }}
    end
  end

  @doc """
  What changed from overview `old` to `new`: the system series whose value differs, the topics that
  changed or appeared, and the names of those that went away; `:unchanged` when nothing did.
  """
  @spec delta(map(), map()) :: map() | :unchanged
  def delta(%{"system" => old_system, "topics" => old_topics}, %{"system" => system, "topics" => topics}) do
    changed_system = for {name, value} <- system, Map.get(old_system, name) != value, into: %{}, do: {name, value}
    changed_topics = for {name, row} <- topics, Map.get(old_topics, name) != row, do: row
    removed = for name <- Map.keys(old_topics), not Map.has_key?(topics, name), do: name

    if changed_system == %{} and changed_topics == [] and removed == [] do
      :unchanged
    else
      %{
        "system" => changed_system,
        "topics" => %{"changed" => Enum.sort_by(changed_topics, & &1["name"]), "removed" => Enum.sort(removed)}
      }
    end
  end

  # --- resuming ---

  defp catch_up(state, nil), do: [snapshot(state)]

  defp catch_up(state, last_event_id) do
    oldest = oldest_sequence(state)

    case parse_id(last_event_id, state.epoch) do
      {:ok, seen} when seen <= state.sequence and seen >= oldest - 1 ->
        for {sequence, event} <- :queue.to_list(state.ring), sequence > seen, do: event

      {:ok, seen} when seen < oldest - 1 ->
        [gap(state, last_event_id, "expired", oldest - seen - 1), snapshot(state)]

      _unknown ->
        [gap(state, last_event_id, "unknown", nil), snapshot(state)]
    end
  end

  # The first sequence still in the ring; one past the last when the ring is empty, so a client current as
  # of the last event resumes with nothing to replay.
  defp oldest_sequence(state) do
    case :queue.peek(state.ring) do
      {:value, {sequence, _event}} -> sequence
      :empty -> state.sequence + 1
    end
  end

  defp gap(state, from, reason, dropped) do
    %{
      id: id(state.epoch, state.sequence),
      event: "gap",
      data: %{
        "type" => "gap",
        "from" => from,
        "to" => id(state.epoch, state.sequence),
        "dropped" => dropped,
        "reason" => reason
      }
    }
  end

  defp snapshot(state) do
    overview = state.overview || %{"system" => %{}, "topics" => %{}}

    data = %{
      "system" => overview["system"],
      "topics" => overview["topics"] |> Map.values() |> Enum.sort_by(& &1["name"]),
      "available" => not state.failing
    }

    %{id: id(state.epoch, state.sequence), event: "snapshot", data: data}
  end

  defp id(epoch, sequence), do: "#{epoch}.#{sequence}"

  defp parse_id(id, epoch) when is_binary(id) do
    with [^epoch, sequence] <- String.split(id, ".", parts: 2),
         {sequence, ""} when sequence >= 0 <- Integer.parse(sequence) do
      {:ok, sequence}
    else
      _other -> :error
    end
  end

  defp setting(key, default) do
    case Application.get_env(:malachi, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
