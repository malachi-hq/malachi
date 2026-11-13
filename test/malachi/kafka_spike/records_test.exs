defmodule Malachi.KafkaSpike.RecordsTest do
  use ExUnit.Case, async: true

  alias Malachi.KafkaSpike.Records
  alias Malachi.Log.Record

  defp kafka_record(fields), do: Map.merge(%{offset: 0, timestamp: 1_000, key: "k", value: "v", headers: []}, fields)

  describe "to_log/1" do
    test "keeps key, value, headers and timestamp" do
      headers = [{"a", "1"}, {"a", "2"}, {"empty", ""}]

      assert {:ok, [%Record{key: "k", value: "v", headers: ^headers, timestamp: 1_000}]} =
               Records.to_log([kafka_record(%{headers: headers})])
    end

    test "keeps a null key as nil and an empty key as empty" do
      assert {:ok, [%Record{key: nil}, %Record{key: ""}]} =
               Records.to_log([kafka_record(%{key: nil}), kafka_record(%{key: ""})])
    end

    test "keeps an empty value and a timestamp of 0" do
      assert {:ok, [%Record{value: "", timestamp: 0}]} = Records.to_log([kafka_record(%{value: "", timestamp: 0})])
    end

    test "is empty for no records" do
      assert Records.to_log([]) == {:ok, []}
    end

    test "refuses a null value, a null header value and a negative timestamp" do
      assert Records.to_log([kafka_record(%{value: nil})]) == {:error, :null_value}
      assert Records.to_log([kafka_record(%{headers: [{"ok", ""}, {"h", nil}]})]) == {:error, :null_header_value}
      assert Records.to_log([kafka_record(%{timestamp: -1})]) == {:error, :negative_timestamp}
    end

    test "refuses the whole list for one bad record, wherever it is" do
      assert Records.to_log([kafka_record(%{}), kafka_record(%{}), kafka_record(%{value: nil})]) ==
               {:error, :null_value}
    end

    test "keeps the order" do
      {:ok, records} = Records.to_log(Enum.map(1..5, &kafka_record(%{value: "#{&1}"})))
      assert Enum.map(records, & &1.value) == ~w(1 2 3 4 5)
    end
  end

  test "from_log/1 is the Kafka record of a stored one" do
    record = %Record{offset: 9, timestamp: 5, key: nil, value: "v", headers: [{"h", "x"}]}
    assert Records.from_log(record) == %{offset: 9, timestamp: 5, key: nil, value: "v", headers: [{"h", "x"}]}
  end
end
