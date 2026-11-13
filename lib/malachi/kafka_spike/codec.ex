defmodule Malachi.KafkaSpike.Codec do
  @moduledoc """
  The Kafka request and response framing, on top of `kafka_protocol`'s message schemas.

  The library is written for clients, and the spike tests whether a server can use it. What it found:

    * Its schemas (`kpro_schema`) describe requests and responses alike, and its struct decoder
      (`kpro_rsp_lib:dec_struct/4`) is exported, so a request body decodes against the request schema.
    * Its struct encoder is private to the request path (`kpro_req_lib:encode/3` takes only requests), so a
      response is encoded here, by walking the response schema with the library's exported primitive
      encoder (`kpro_lib:encode/2`).
    * It stops at the versions it knows: Produce v8, Fetch v11, Metadata v9, ApiVersions v3,
      InitProducerId v2. Those are what the spike advertises.

  A request frame is `size int32 | api_key int16 | api_version int16 | correlation_id int32 |
  client_id nullable_string | [tagged_fields when flexible] | body`. A response frame is `size int32 |
  correlation_id int32 | [tagged_fields when flexible] | body`, except that an ApiVersions response header
  never carries tagged fields, whatever its version, so a client can read it before it knows what the
  broker supports.
  """

  @typedoc "A decoded request header."
  @type header :: %{
          api_key: integer(),
          api: atom() | nil,
          vsn: integer(),
          correlation_id: integer(),
          client_id: binary() | nil
        }

  @doc """
  The header of a request frame (without its size prefix) and the body after it. `api` is nil for an API
  `kafka_protocol` does not know, whose header can still be read for logging up to its client id.
  """
  @spec decode_header(binary()) :: {:ok, header(), binary()} | {:error, :malformed}
  def decode_header(<<api_key::16-signed, vsn::16-signed, correlation_id::32-signed, rest::binary>>) do
    with {:ok, client_id, rest} <- nullable_string(rest) do
      api = api_name(api_key)
      header = %{api_key: api_key, api: api, vsn: vsn, correlation_id: correlation_id, client_id: client_id}
      header_tags(header, rest)
    end
  end

  def decode_header(_short), do: {:error, :malformed}

  defp nullable_string(<<-1::16-signed, rest::binary>>), do: {:ok, nil, rest}

  defp nullable_string(<<length::16-signed, string::binary-size(length), rest::binary>>) when length >= 0,
    do: {:ok, string, rest}

  defp nullable_string(_short), do: {:error, :malformed}

  # Request header v2 (a flexible version) adds tagged fields after the client id. An API the library does
  # not know has no known flexible version, and its body is never decoded anyway.
  defp header_tags(%{api: nil} = header, rest), do: {:ok, header, rest}

  defp header_tags(%{api: api, vsn: vsn} = header, rest) do
    if flexible?(api, vsn) do
      case decode_primitive(:tagged_fields, rest) do
        {:ok, _tags, rest} -> {:ok, header, rest}
        :error -> {:error, :malformed}
      end
    else
      {:ok, header, rest}
    end
  end

  defp api_name(api_key) do
    :kpro_schema.api_key(api_key)
  rescue
    ErlangError -> nil
  end

  @doc "Whether `vsn` of `api` is a flexible version (compact types and tagged fields)."
  @spec flexible?(atom(), integer()) :: boolean()
  def flexible?(api, vsn), do: vsn >= :kpro_schema.min_flexible_vsn(api)

  @doc """
  The body of a request of `api` at `vsn`, as the map `kafka_protocol` decodes it to, or `:malformed` when
  it does not parse or leaves bytes behind.
  """
  @spec decode_body(atom(), integer(), binary()) :: {:ok, map()} | {:error, :malformed}
  def decode_body(api, vsn, body) do
    schema = :kpro_lib.get_req_schema(api, vsn)

    case :kpro_rsp_lib.dec_struct(schema, %{}, [{api, vsn}], body) do
      {fields, <<>>} -> {:ok, fields}
      {_fields, _trailing} -> {:error, :malformed}
    end
  rescue
    _error -> {:error, :malformed}
  end

  defp decode_primitive(type, bin) do
    {value, rest} = :kpro_lib.decode(type, bin)
    {:ok, value, rest}
  rescue
    _error -> :error
  end

  @doc """
  The frame answering `correlation_id` with `body` encoded as the response of `api` at `vsn`, its size
  prefix included. `body` holds every field the version's schema names (it may hold more: fields of other
  versions are ignored), arrays as lists, nullable values as nil. A missing field raises, since it is a
  bug in the spike, not in the client.
  """
  @spec encode_response(atom(), integer(), integer(), map()) :: iodata()
  def encode_response(api, vsn, correlation_id, body) do
    header =
      if api != :api_versions and flexible?(api, vsn),
        do: <<correlation_id::32-signed, 0::8>>,
        else: <<correlation_id::32-signed>>

    payload = [header | encode_struct(:kpro_lib.get_rsp_schema(api, vsn), body, [api])]
    [<<IO.iodata_length(payload)::32-signed>> | payload]
  end

  defp encode_struct(schema, values, path) do
    Enum.map(schema, fn {name, field_schema} ->
      encode_field(field_schema, field_value(values, name, path), [name | path])
    end)
  end

  defp field_value(_values, :tagged_fields, _path), do: %{}

  defp field_value(values, name, path) do
    case Map.fetch(values, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing #{name} in #{inspect(Enum.reverse(path))}"
    end
  end

  defp encode_field({:array, _schema}, nil, _path), do: <<-1::32-signed>>
  defp encode_field({:compact_array, _schema}, nil, _path), do: <<0::8>>

  defp encode_field({:array, schema}, values, path) when is_list(values),
    do: [<<length(values)::32-signed>> | Enum.map(values, &encode_field(schema, &1, path))]

  defp encode_field({:compact_array, schema}, values, path) when is_list(values),
    do: [:kpro_varint.encode_unsigned(length(values) + 1) | Enum.map(values, &encode_field(schema, &1, path))]

  defp encode_field(schema, value, path) when is_list(schema), do: encode_struct(schema, value, path)

  # kpro_lib encodes a null nullable_string, but not a null bytes or records; a Fetch response's record
  # set is never null here (an empty one is <<>>).
  defp encode_field(:nullable_string, nil, _path), do: <<-1::16-signed>>
  defp encode_field(:compact_nullable_string, nil, _path), do: <<0::8>>
  defp encode_field(type, value, _path) when is_atom(type), do: :kpro_lib.encode(type, value)
end
