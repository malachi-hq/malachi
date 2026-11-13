defmodule Malachi.KafkaSpike do
  @moduledoc """
  A throwaway listener that speaks the Kafka wire protocol (#166), started beside the Malachi listener
  only when `config :malachi, :kafka_spike, port:` is set.

  It exists to answer three questions before any gateway code is written: whether `kafka_protocol` can
  serve the server side, what Kafka clients do against a broker that does or does not offer
  InitProducerId, and which APIs MirrorMaker 2 needs. It answers ApiVersions, Metadata, Produce and
  Fetch for one topic as Kafka partition 0, backed by the node's broker; nothing here is meant to
  survive into the gateway (#165).

  It has no authentication and no ACLs: any client that reaches it can produce to and fetch from its
  topic. That is why it is off by default and binds the loopback address unless told otherwise, and why
  it serves one configured topic and nothing else.

  Options (all optional but `:port`):

    * `:port`: the port to listen on; nil (the default) starts nothing, 0 asks the system for one.
    * `:ip`: the address to bind, `{127, 0, 0, 1}` by default.
    * `:advertised_host` and `:advertised_port`: what Metadata tells clients to connect to, by default
      `"127.0.0.1"` and the port the listener bound.
    * `:node_id`: the broker id Metadata announces, 0 by default.
    * `:topic`: the topic served as partition 0, `"kafka-spike"` by default.
    * `:idempotence`: `:hide` (the default) leaves InitProducerId out of ApiVersions; `:advertise` answers
      it with fresh producer ids, without deduplicating sequences.
    * `:max_wait_cap_ms`: the longest a Fetch waits for records, whatever the client asks, 1000 by default.
    * `:capture_dir`: when set, the first request frame of each client, API and version is written there
      (`Malachi.KafkaSpike.Connection.capture/2`), for the codec tests to replay. Nil by default.
  """
  use Supervisor
  alias Malachi.KafkaSpike.Acceptor
  alias Malachi.TCPAcceptorPool

  @pool Malachi.KafkaSpike.Pool

  @defaults [
    port: nil,
    ip: {127, 0, 0, 1},
    advertised_host: "127.0.0.1",
    advertised_port: nil,
    node_id: 0,
    topic: "kafka-spike",
    idempotence: :hide,
    max_wait_cap_ms: 1_000,
    capture_dir: nil
  ]

  @doc "The spike's child spec when `config` sets a port, none otherwise."
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(config \\ Application.get_env(:malachi, :kafka_spike, [])) do
    if Keyword.get(config, :port), do: [{__MODULE__, config}], else: []
  end

  @doc "Starts the listener with `config` (see the moduledoc), registered under the module name."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    config = Keyword.merge(@defaults, config)
    idempotence = Keyword.fetch!(config, :idempotence)

    unless idempotence in [:advertise, :hide],
      do: raise(ArgumentError, "kafka_spike idempotence must be :advertise or :hide, got #{inspect(idempotence)}")

    :persistent_term.put({__MODULE__, :config}, %{
      topic: Keyword.fetch!(config, :topic),
      node_id: Keyword.fetch!(config, :node_id),
      host: Keyword.fetch!(config, :advertised_host),
      advertised_port: Keyword.fetch!(config, :advertised_port),
      idempotence: idempotence,
      max_wait_cap_ms: Keyword.fetch!(config, :max_wait_cap_ms),
      capture_dir: Keyword.fetch!(config, :capture_dir),
      producer_ids: :atomics.new(1, signed: true)
    })

    pool_opts = [name: @pool, acceptor: Acceptor, ip: Keyword.fetch!(config, :ip), tls: false]
    Supervisor.init([{TCPAcceptorPool, {Keyword.fetch!(config, :port), pool_opts}}], strategy: :one_for_one)
  end

  @doc "The port the listener bound, or nil when it never started."
  @spec port() :: :inet.port_number() | nil
  def port, do: TCPAcceptorPool.port(@pool)

  @doc "The configuration a connection is served under (`t:Malachi.KafkaSpike.Handler.ctx/0`)."
  @spec ctx() :: Malachi.KafkaSpike.Handler.ctx()
  def ctx do
    {advertised_port, config} = Map.pop(:persistent_term.get({__MODULE__, :config}), :advertised_port)
    Map.put(config, :port, advertised_port || port())
  end

  @doc "The largest request frame a connection reads, the Malachi listener's own limit."
  @spec max_frame_size() :: pos_integer()
  def max_frame_size, do: Application.get_env(:malachi, :max_frame_size, 16_777_216)
end
