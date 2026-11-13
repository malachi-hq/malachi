defmodule Malachi.KafkaSpike.ErrorCodesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Malachi.KafkaSpike.ErrorCodes

  @table [
    no_such_topic: {:unknown_topic_or_partition, 3},
    no_such_range: {:unknown_topic_or_partition, 3},
    split_topic: {:unknown_topic_or_partition, 3},
    not_primary: {:not_leader_or_follower, 6},
    no_quorum: {:not_enough_replicas, 19},
    enospc: {:kafka_storage_error, 56},
    eio: {:kafka_storage_error, 56},
    eacces: {:kafka_storage_error, 56},
    timeout: {:request_timed_out, 7},
    broker_down: {:broker_not_available, 8},
    invalid_position: {:offset_out_of_range, 1},
    metadata_unavailable: {:leader_not_available, 5},
    unavailable: {:leader_not_available, 5},
    corrupt_batch: {:corrupt_message, 2},
    compressed_batch: {:unsupported_compression_type, 76},
    unsupported_magic: {:unsupported_for_message_format, 43},
    transactional_batch: {:invalid_record, 87},
    control_batch: {:invalid_record, 87},
    transactions_unsupported: {:invalid_request, 42},
    null_value: {:invalid_record, 87},
    null_header_value: {:invalid_record, 87},
    negative_timestamp: {:invalid_record, 87}
  ]

  for {reason, {name, code}} <- @table do
    test "#{reason} is #{name} (#{code})" do
      assert ErrorCodes.from_reason(unquote(reason)) == unquote(name)
      assert ErrorCodes.code_for(unquote(reason)) == unquote(code)
    end
  end

  test "a tagged storage failure is KAFKA_STORAGE_ERROR" do
    assert ErrorCodes.from_reason({:storage, :enospc}) == :kafka_storage_error
  end

  test "the codes match Kafka's" do
    for {name, code} <- [none: 0, unknown_server_error: -1, unsupported_version: 35, invalid_request: 42] do
      assert ErrorCodes.code(name) == code
    end
  end

  test "agrees with kafka_protocol's table on every code it answers" do
    # kafka_protocol still uses the name code 6 had before KIP-392 renamed it
    renamed = %{not_leader_or_follower: :not_leader_for_partition}
    for {_reason, {name, code}} <- @table, do: assert(:kpro_schema.ec(code) == Map.get(renamed, name, name))
  end

  test "a reason with no clause is UNKNOWN_SERVER_ERROR, and logged" do
    log = capture_log(fn -> assert ErrorCodes.from_reason({:something, :new}) == :unknown_server_error end)
    assert log =~ "{:something, :new}"
  end

  test "an unknown error name raises" do
    assert_raise KeyError, fn -> ErrorCodes.code(:not_a_kafka_error) end
  end
end
