defmodule Malachi.KafkaSpike.CodecTest do
  use ExUnit.Case, async: true

  alias Malachi.KafkaSpike.Codec
  alias Malachi.KafkaSpike.RecordBatch
  alias Malachi.Test.KafkaClient

  # Request frames as real clients sent them to the spike, captured by benchmark/kafka-spike/clients.sh
  # (the spike's capture_dir): the Java client 3.9.2 and 4.4.0 and kcat 1.7.1 (librdkafka 1.8.2), named
  # <client id>-<api key>-v<version>.bin.
  @fixtures Path.expand("../../fixtures/kafka", __DIR__)
  @frames @fixtures |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".bin")) |> Enum.sort()
  @parsed Map.new(@frames, fn name ->
            [_, client, key, vsn] = Regex.run(~r/^(.*)-(\d+)-v(\d+)\.bin$/, name)
            {name, {client, String.to_integer(key), String.to_integer(vsn)}}
          end)

  defp frame(name), do: File.read!(Path.join(@fixtures, name))

  defp parse_name(name), do: Map.fetch!(@parsed, name)

  test "the fixtures hold every client and every API the spike answers" do
    parsed = Enum.map(@frames, &parse_name/1)

    assert parsed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             ["java-3.9.2-consumer", "java-3.9.2-producer", "java-4.4.0-consumer", "java-4.4.0-producer", "rdkafka"]

    assert parsed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort() == [0, 1, 3, 18, 22]
  end

  describe "a captured frame" do
    for name <- @frames do
      {client, api_key, vsn} = Map.fetch!(@parsed, name)
      {_min, max} = :kpro_schema.vsn_range(:kpro_schema.api_key(api_key))

      test "#{name}: the header names its API, version and client" do
        assert {:ok, header, _body} = Codec.decode_header(frame(unquote(name)))
        assert {header.api_key, header.vsn, header.client_id} == {unquote(api_key), unquote(vsn), unquote(client)}
        assert header.api == :kpro_schema.api_key(unquote(api_key))
      end

      if vsn <= max do
        test "#{name}: the body decodes whole, and kafka_protocol encodes it back to the same bytes" do
          frame = frame(unquote(name))
          {:ok, header, body} = Codec.decode_header(frame)
          assert {:ok, request} = Codec.decode_body(header.api, header.vsn, body)

          # kafka_protocol decodes a null nullable_string as <<>>, so a Produce's null transactional id
          # comes back empty: restored here, and pinned on its own below
          request = if header.api == :produce, do: %{request | transactional_id: :undefined}, else: request
          reencoded = KafkaClient.request(header.api, header.vsn, request, header.correlation_id, header.client_id)
          assert reencoded == frame
        end
      else
        test "#{name}: a version past kafka_protocol's schemas, which ApiVersions answers as v0" do
          {:ok, header, _body} = Codec.decode_header(frame(unquote(name)))
          assert header.api == :api_versions
          assert header.vsn > 3
        end
      end
    end

    test "kafka_protocol reads a Produce's null transactional id as an empty one" do
      for name <- @frames, match?({_client, 0, _vsn}, parse_name(name)) do
        {:ok, header, body} = Codec.decode_header(frame(name))
        # the request body starts with the transactional id: -1 is null on the wire
        assert <<-1::16-signed, _rest::binary>> = body
        assert {:ok, %{transactional_id: <<>>}} = Codec.decode_body(:produce, header.vsn, body)
      end
    end

    test "every captured Produce carries record batches the spike decodes" do
      for name <- @frames, match?({_client, 0, _vsn}, parse_name(name)) do
        {:ok, header, body} = Codec.decode_header(frame(name))
        {:ok, %{topic_data: [%{data: [%{record_set: set}]}]}} = Codec.decode_body(:produce, header.vsn, body)
        assert {:ok, [_ | _] = batches} = RecordBatch.decode(set), name
        assert Enum.all?(batches, &(&1.records != []))
      end
    end
  end

  describe "decode_header/1" do
    test "a null client id is nil" do
      assert {:ok, %{client_id: nil, api: :api_versions}, <<>>} =
               Codec.decode_header(<<18::16, 0::16, 7::32, -1::16-signed>>)
    end

    test "a flexible version without its header tagged fields is malformed" do
      assert {:error, :malformed} = Codec.decode_header(<<18::16, 3::16, 7::32, -1::16-signed>>)
    end

    test "a client id longer than the frame is malformed" do
      assert {:error, :malformed} = Codec.decode_header(<<3::16, 9::16, 1::32, 50::16, "short">>)
    end

    test "an API kafka_protocol does not know has no name, and its body is left alone" do
      assert {:ok, %{api: nil, api_key: 1_000}, <<1, 2, 3>>} =
               Codec.decode_header(<<1_000::16, 0::16, 1::32, 0::16, 1, 2, 3>>)
    end
  end

  describe "encode_response/4" do
    test "an ApiVersions response header has no tagged fields, at any version" do
      body = %{error_code: 0, api_keys: [], throttle_time_ms: 0}
      <<_size::32, 5::32, rest::binary>> = IO.iodata_to_binary(Codec.encode_response(:api_versions, 3, 5, body))
      # error_code, then the compact array of no api keys: no header tag byte before them
      assert <<0::16, 1, _::binary>> = rest
    end

    test "a flexible response header carries an empty tagged field section" do
      body = %{throttle_time_ms: 0, error_code: 0, producer_id: 1, producer_epoch: 0}
      frame = IO.iodata_to_binary(Codec.encode_response(:init_producer_id, 2, 5, body))
      assert <<_size::32, 5::32, 0, 0::32, _::binary>> = frame
    end

    test "the size prefix is the length of what follows" do
      body = %{throttle_time_ms: 0, error_code: 0, producer_id: 1, producer_epoch: 0}
      <<size::32, rest::binary>> = IO.iodata_to_binary(Codec.encode_response(:init_producer_id, 0, 1, body))
      assert size == byte_size(rest)
    end

    test "encodes null arrays and null strings, compact or not" do
      body = %{
        throttle_time_ms: 0,
        brokers: [%{node_id: 1, host: "h", port: 1, rack: nil}],
        cluster_id: nil,
        controller_id: 1,
        topics: nil,
        cluster_authorized_operations: 0
      }

      for vsn <- [8, 9] do
        frame = Codec.encode_response(:metadata, vsn, 1, body)
        assert {1, %{topics: :undefined, brokers: [%{rack: rack}]}} = KafkaClient.response(:metadata, vsn, frame)
        # kafka_protocol reads a null non-compact string as empty, a null compact one as undefined
        assert rack in [<<>>, :undefined]
      end
    end

    test "a field the version names but the body lacks raises, naming it" do
      assert_raise ArgumentError, ~r/missing producer_epoch in \[:init_producer_id\]/, fn ->
        Codec.encode_response(:init_producer_id, 2, 1, %{throttle_time_ms: 0, error_code: 0, producer_id: 1})
      end
    end
  end

  test "flexible?/2 follows kafka_protocol's table" do
    assert Codec.flexible?(:metadata, 9)
    refute Codec.flexible?(:metadata, 8)
    refute Codec.flexible?(:produce, 8)
    assert Codec.flexible?(:api_versions, 3)
  end
end
