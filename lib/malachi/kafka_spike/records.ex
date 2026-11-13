defmodule Malachi.KafkaSpike.Records do
  @moduledoc """
  A Kafka record to a `Malachi.Log.Record` and back.

  A Kafka record carries what a Malachi record cannot: a null value (a tombstone), a header with a null
  value, and a negative timestamp. The spike refuses those rather than invent a representation that #167
  would have to undo, and each refusal is a server requirement the findings hand to #167. A null key is
  kept as `nil`, which a Malachi record already holds.
  """
  alias Malachi.KafkaSpike.RecordBatch
  alias Malachi.Log.Record

  @typedoc "Why a Kafka record cannot become a Malachi record."
  @type refusal :: :null_value | :null_header_value | :negative_timestamp

  @doc "The Malachi records of `kafka_records`, or the first reason one of them cannot be stored."
  @spec to_log([RecordBatch.kafka_record()]) :: {:ok, [Record.t()]} | {:error, refusal()}
  def to_log(kafka_records) do
    Enum.reduce_while(kafka_records, {:ok, []}, fn kafka_record, {:ok, acc} ->
      case to_record(kafka_record) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp to_record(%{value: nil}), do: {:error, :null_value}
  defp to_record(%{timestamp: timestamp}) when timestamp < 0, do: {:error, :negative_timestamp}

  defp to_record(%{key: key, value: value, headers: headers, timestamp: timestamp}) do
    if Enum.any?(headers, fn {_key, header_value} -> is_nil(header_value) end),
      do: {:error, :null_header_value},
      else: {:ok, %Record{key: key, value: value, headers: headers, timestamp: timestamp}}
  end

  @doc "The Kafka record a stored Malachi record is fetched as, at its range offset."
  @spec from_log(Record.t()) :: RecordBatch.kafka_record()
  def from_log(%Record{offset: offset, timestamp: timestamp, key: key, value: value, headers: headers}),
    do: %{offset: offset, timestamp: timestamp, key: key, value: value, headers: headers}
end
