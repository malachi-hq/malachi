# What does a produce cost the broker loop when consume streams tail the range it writes?
#
# Every produce wakes the consume streams caught up on its range. Before the view epoch
# (`Malachi.Broker.view_epoch/1`) each wake rebuilt a `Malachi.Broker.ReadView` of the range, walking every
# segment it retains (and its ancestors'), and sent that view to each woken stream, a copy per stream. With
# the epoch the view is built once per epoch and a stream already holding it is sent only the range's new
# end. The cost moved is O(segments) per produce plus O(segments) per woken stream, all of it in the
# process that serializes the range's appends, so this times produces through that process with the
# paired protocol of store_error_path_ab.exs: arms interleaved by run in a shuffled order, an A-A
# control, and the fixed verdict rule of `support/paired_stats.exs`.
#
# One sample builds a range of @segments[-1] sealed segments (one record each), by produces with a
# segment size of one record, and then raises the segment size so the produces it times stay in one
# active segment, as on a range with a long retention (`:sys.replace_state/2`, the only knob both trees
# share). For each retained count in @segments and each count of tailing streams in @streams it times
# @rounds rounds of @produces_per_round one-record produces. A tailing stream is a process that arms its
# stream again at the end each wake carries, as `Malachi.ConsumeStreams` does once it has read the view.
#
# Modes (normally driven by wake_view_ab.sh, not by hand):
#   AB_MODE=sample AB_DIR=/scratch           mix run benchmark/wake_view_ab.exs
#   AB_MODE=analyze AB_RESULTS=dir AB_OUT=file mix run --no-start benchmark/wake_view_ab.exs

Code.require_file("support/ab_run.exs", __DIR__)

defmodule WakeViewAB do
  import Bitwise

  alias Malachi.Bench.ABRun
  alias Malachi.Bench.PairedStats
  alias Malachi.Broker.ReadView
  alias Malachi.BrokerServer
  alias Malachi.Log.Record

  @segments [1, 100, 1000]
  @streams [1, 10, 100]
  @rounds 40
  @produces_per_round 25

  @doc "One repetition, printed as a single marked JSON line."
  def sample(directory) do
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    one_record = Record.encoded_size(record(0))
    {:ok, server} = BrokerServer.start_link(directory, segment_max_bytes: one_record)
    {:ok, root} = BrokerServer.create_topic(server, "wake_view_ab", 1)

    {results, _retained} =
      Enum.flat_map_reduce(@segments, 0, fn segments, retained ->
        retain(server, root, retained, segments)
        long_segments(server)

        cases =
          for streams <- @streams do
            {"s#{segments}_n#{streams}", PairedStats.summarize(timed(server, root, streams))}
          end

        short_segments(server, one_record)
        {cases, segments}
      end)

    ABRun.emit(Map.new(results))
  end

  # Seals produces until `root` retains `segments` segments, each sealed by its own produce's roll.
  defp retain(server, root, retained, segments) do
    for n <- retained..(segments - 1)//1, do: {:ok, _} = BrokerServer.produce(server, "wake_view_ab", [record(n)])
    wait_sealed(server, root, segments, 500)
  end

  defp wait_sealed(server, root, segments, attempts) do
    sealed =
      server
      |> BrokerServer.metadata()
      |> Malachi.Metadata.segments_of_range(root)
      |> Enum.count(&(&1.state == :sealed))

    cond do
      sealed >= segments -> :ok
      attempts > 0 -> Process.sleep(10) && wait_sealed(server, root, segments, attempts - 1)
      true -> raise "#{segments} segments never sealed (#{sealed})"
    end
  end

  defp long_segments(server),
    do: :sys.replace_state(server, &put_in(&1.broker.segment_max_bytes, 1 <<< 40))

  defp short_segments(server, bytes), do: :sys.replace_state(server, &put_in(&1.broker.segment_max_bytes, bytes))

  # The microseconds of each round of produces, with `streams` tailing consume streams on `root`.
  defp timed(server, root, streams) do
    tails = for _ <- 1..streams, do: tail(server, root)

    rounds =
      for _ <- 1..@rounds do
        started = System.monotonic_time(:microsecond)

        for _ <- 1..@produces_per_round,
            do: {:ok, _} = BrokerServer.produce(server, "wake_view_ab", [record(:rand.uniform(1 <<< 30))])

        System.monotonic_time(:microsecond) - started
      end

    Enum.each(tails, &stop_tail(server, &1))
    rounds
  end

  defp tail(server, root) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, token, _position, _server} = BrokerServer.open_consume(server, root, :latest, self())
        send(parent, {:tailing, self(), token})
        follow(server, root, token)
      end)

    receive do
      {:tailing, ^pid, token} -> {pid, token}
    end
  end

  # Arms the stream again at the end each wake carries: the view's end, or only the end when the broker
  # sends no view.
  defp follow(server, root, token) do
    receive do
      {:consume_wake, ^token, wake, _reporter} ->
        :ok = BrokerServer.arm_consume(server, token, wake_end(wake, root))
        follow(server, root, token)

      :stop ->
        :ok
    end
  end

  defp wake_end(%ReadView{} = view, root), do: view |> ReadView.fetch_end(root) |> elem(1)
  defp wake_end({:unchanged, durable_end}, _root), do: durable_end

  defp stop_tail(server, {pid, token}) do
    :ok = BrokerServer.close_stream(server, token)
    send(pid, :stop)
  end

  defp record(n), do: Record.new("v#{n}", key: "k")

  @doc "Reads the samples under `results` and judges them (see `Malachi.Bench.ABRun.analyze/5`)."
  def analyze(results, out) do
    names = for segments <- @segments, streams <- @streams, do: "s#{segments}_n#{streams}"
    cases = for name <- names, do: {name, "wake", &parse(&1, name)}

    ABRun.analyze(results, out, names, cases, %{
      rounds: @rounds,
      produces_per_round: @produces_per_round,
      segments: @segments,
      streams: @streams
    })
  end

  defp parse(output, name) do
    %{"p50" => p50, "p99" => p99} = output |> ABRun.marked() |> Map.fetch!(name)
    %{p50: p50, p99: p99}
  end
end

case System.get_env("AB_MODE") do
  "sample" -> WakeViewAB.sample(System.fetch_env!("AB_DIR"))
  "analyze" -> WakeViewAB.analyze(System.fetch_env!("AB_RESULTS"), System.get_env("AB_OUT"))
  other -> raise ArgumentError, "AB_MODE must be sample or analyze, got: #{inspect(other)}"
end
