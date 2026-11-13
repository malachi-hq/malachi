defmodule Malachi.KafkaSpike.Topic do
  @moduledoc """
  The one topic the spike serves, as Kafka partition 0, and the Malachi range behind it.

  The topic is created on first use, idempotently: a topic that already exists is taken as it is. Creation
  waits for the first request rather than the listener's start, because at boot the control plane may not
  have answered yet, and a request that meets that is answered `LEADER_NOT_AVAILABLE`, which every Kafka
  client retries. Once resolved, the range is cached for the node's lifetime.

  A Kafka partition's offsets must never move, and a split child restarts its offsets at 0 (#165), so the
  spike serves the topic only while it is one range: a topic that was split is refused.
  """
  alias Malachi.BrokerServer
  alias Malachi.DataPlaneRouter
  alias Malachi.Routing

  # The keyspace size every Malachi topic is created with (`Malachi.LogApi`); one range covers all of it.
  @keyspace_bits 8

  @doc "The broker server that owns `topic`'s data plane on this node."
  @spec broker(binary()) :: GenServer.server()
  def broker(topic), do: DataPlaneRouter.shard_for(topic)

  @doc """
  The range id of `topic`'s only range, creating the topic first when it does not exist yet.
  `{:error, :split_topic}` when the topic holds more than one range, or the error that creating it or
  reading its routes answered.
  """
  @spec resolve(binary()) :: {:ok, Malachi.Metadata.range_id()} | {:error, term()}
  def resolve(topic) do
    case :persistent_term.get({__MODULE__, topic}, nil) do
      nil -> resolve_and_cache(topic)
      range_id -> {:ok, range_id}
    end
  end

  @doc "Forgets the cached range of `topic` (for a test that deletes and recreates its data)."
  @spec forget(binary()) :: :ok
  def forget(topic) do
    :persistent_term.erase({__MODULE__, topic})
    :ok
  end

  defp resolve_and_cache(topic) do
    with :ok <- ensure_created(topic),
         {:ok, %{ranges: ranges}} <- Routing.read_topic_routes(topic),
         {:ok, range_id} <- only_range(topic, ranges) do
      :persistent_term.put({__MODULE__, topic}, range_id)
      {:ok, range_id}
    end
  end

  defp ensure_created(topic) do
    case BrokerServer.create_topic(broker(topic), topic, @keyspace_bits) do
      {:ok, _root} -> :ok
      {:error, :already_exists} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp only_range(topic, [%{range: seq}]), do: {:ok, {topic, seq}}
  defp only_range(_topic, _ranges), do: {:error, :split_topic}
end
