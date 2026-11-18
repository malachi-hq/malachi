defmodule Malachi.ResultsText do
  @moduledoc """
  The sentences and number formats that describe a published measurement, shared by the generated results
  pages (`mix malachi.docs.results`), the blog's charts (`Malachi.Site.Chart`) and the release post generator
  (`mix malachi.release.post`, issue #373), so the site says the same thing about noise and prints a number the
  same way wherever it appears.
  """

  @doc "An integer with its digits grouped by thousands: `357650` is `357,650`."
  @spec group_digits(integer()) :: String.t()
  def group_digits(value) when is_integer(value) and value < 0, do: "-" <> group_digits(-value)

  def group_digits(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  @doc """
  What the run's A-A repeat says about its own noise, from the `sweep` of a load test result: how far repeating
  the headline peak moved it, or that no repeat was recorded and why. `compared` names what the reader compares
  against that noise: the batch sizes of a results page, or the releases of a release post.
  """
  @spec aa_sentence(map() | nil, String.t()) :: String.t()
  def aa_sentence(sweep, compared \\ "batch sizes")

  def aa_sentence(%{"aa_control" => %{"delta_pct" => delta} = aa}, compared) when is_number(delta) do
    "Repeating the headline peak moved it #{delta}% (#{number(aa["first_records_per_s"])} then " <>
      "#{number(aa["repeat_records_per_s"])} records per second), so a difference between #{compared} smaller " <>
      "than that is noise."
  end

  def aa_sentence(%{"aa_control_reason" => reason}, _compared) when is_binary(reason),
    do: "No A-A repeat of the headline peak was recorded (#{reason}), so this run carries no noise estimate."

  def aa_sentence(_sweep, _compared),
    do: "No A-A repeat of the headline peak was recorded, so this run carries no noise estimate."

  @doc "Why two runs on shared CI runners are not compared as a gain or a loss."
  @spec cross_run_sentence() :: String.t()
  def cross_run_sentence,
    do: "On a shared CI runner the published ceiling has moved by more than 30% between runs of unchanged code."

  defp number(value) when is_integer(value), do: group_digits(value)
  defp number(value), do: value
end
