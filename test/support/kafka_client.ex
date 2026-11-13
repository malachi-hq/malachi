defmodule Malachi.Test.KafkaClient do
  @moduledoc """
  A Kafka client for the spike's tests, built on `kafka_protocol` used the way it was written for: it
  encodes requests and decodes responses. The spike decodes the requests and encodes the responses, so a
  round trip through both checks the server side against the library's own client side.
  """
  require Record

  Record.defrecord(:kpro_req, Record.extract(:kpro_req, from_lib: "kafka_protocol/include/kpro.hrl"))
  Record.defrecord(:kpro_rsp, Record.extract(:kpro_rsp, from_lib: "kafka_protocol/include/kpro.hrl"))

  @doc "The request frame (without its size prefix) for `fields` as `api` at `vsn`."
  @spec request(atom(), integer(), map(), integer(), binary()) :: binary()
  def request(api, vsn, fields, correlation_id \\ 1, client_id \\ "malachi-test") do
    req = :kpro_req_lib.make(api, vsn, fields)
    IO.iodata_to_binary(:kpro_req_lib.encode(client_id, correlation_id, req))
  end

  @doc "The frame (without its size prefix) of an already built `kpro_req`."
  @spec encode(tuple(), integer()) :: binary()
  def encode(req, correlation_id \\ 1),
    do: IO.iodata_to_binary(:kpro_req_lib.encode("malachi-test", correlation_id, req))

  @doc """
  A response frame (its size prefix included, as the spike encodes it) decoded as `api` at `vsn`:
  `{correlation_id, body}`. The size prefix must match the frame's length.
  """
  @spec response(atom(), integer(), iodata()) :: {integer(), map()}
  def response(api, vsn, frame) do
    <<size::32-signed, rest::binary>> = IO.iodata_to_binary(frame)
    ^size = byte_size(rest)
    <<correlation_id::32-signed, body::binary>> = rest
    # An ApiVersions response header has no tagged fields at any version, but kafka_protocol strips them
    # for flexible versions: hand it the byte it expects.
    body = if api == :api_versions and vsn >= 3, do: <<0, body::binary>>, else: body
    {correlation_id, kpro_rsp(:kpro_rsp_lib.decode(api, vsn, body, false), :msg)}
  end

  @doc "A produce request of `messages` (`[%{key:, value:, ts:, headers:}]`) to partition 0 of `topic`."
  @spec produce(integer(), binary(), [map()], map()) :: binary()
  def produce(vsn, topic, messages, opts \\ %{}),
    do: encode(:kpro_req_lib.produce(vsn, topic, 0, messages, opts))

  @doc "A fetch request of partition 0 of `topic` from `offset`."
  @spec fetch(integer(), binary(), integer(), map()) :: binary()
  def fetch(vsn, topic, offset, opts \\ %{}), do: encode(:kpro_req_lib.fetch(vsn, topic, 0, offset, opts))

  @doc "Sends `frame` over `socket` with its size prefix and reads one response frame back."
  @spec round_trip(:gen_tcp.socket(), binary()) :: binary()
  def round_trip(socket, frame) do
    :ok = :gen_tcp.send(socket, [<<byte_size(frame)::32-signed>>, frame])
    read_response(socket)
  end

  @doc "Reads one response frame, its size prefix included."
  @spec read_response(:gen_tcp.socket()) :: binary()
  def read_response(socket) do
    {:ok, <<size::32-signed>> = prefix} = :gen_tcp.recv(socket, 4, 5_000)
    {:ok, rest} = :gen_tcp.recv(socket, size, 5_000)
    prefix <> rest
  end
end
