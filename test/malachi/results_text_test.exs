defmodule Malachi.ResultsTextTest do
  use ExUnit.Case, async: true

  alias Malachi.ResultsText

  test "group_digits/1 groups by thousands, a negative number too" do
    assert ResultsText.group_digits(0) == "0"
    assert ResultsText.group_digits(999) == "999"
    assert ResultsText.group_digits(1000) == "1,000"
    assert ResultsText.group_digits(357_650) == "357,650"
    assert ResultsText.group_digits(-1_234_567) == "-1,234,567"
  end

  test "aa_sentence/1 states the A-A repeat, the reason it is missing, or that it is missing" do
    assert ResultsText.aa_sentence(%{
             "aa_control" => %{"delta_pct" => -0.8, "first_records_per_s" => 37_448, "repeat_records_per_s" => 37_146}
           }) =~ "moved it -0.8% (37,448 then 37,146 records per second)"

    assert ResultsText.aa_sentence(%{
             "aa_control" => %{"delta_pct" => 1.5, "first_records_per_s" => 10.5, "repeat_records_per_s" => 10.6}
           }) =~ "(10.5 then 10.6 records per second)"

    assert ResultsText.aa_sentence(%{
             "aa_control" => %{"delta_pct" => 1, "first_records_per_s" => 1, "repeat_records_per_s" => 1}
           }) =~
             "a difference between batch sizes smaller than that is noise"

    assert ResultsText.aa_sentence(
             %{"aa_control" => %{"delta_pct" => 1, "first_records_per_s" => 1, "repeat_records_per_s" => 1}},
             "releases"
           ) =~
             "a difference between releases smaller than that is noise"

    assert ResultsText.aa_sentence(%{"aa_control_reason" => "no clean peak"}) =~ "(no clean peak)"
    assert ResultsText.aa_sentence(nil) =~ "carries no noise estimate"
    assert ResultsText.aa_sentence(%{"aa_control" => %{"delta_pct" => nil}}) =~ "carries no noise estimate"
  end

  test "cross_run_sentence/0 names the spread between runs of unchanged code" do
    assert ResultsText.cross_run_sentence() =~ "more than 30% between runs of unchanged code"
  end
end
