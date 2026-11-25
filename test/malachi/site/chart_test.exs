defmodule Malachi.Site.ChartTest do
  use ExUnit.Case, async: true

  alias Malachi.Site.Chart

  @json ~s({"name": "produce-rate", "title": "Produce rate", "unit": "records/s",
  "points": [{"label": "v0.28.1", "value": 37146}, {"label": "v0.28.2", "value": null}]})

  describe "parse/1" do
    test "reads a chart's name, title, unit and points, a null value kept as a gap" do
      assert {:ok, chart} = Chart.parse(@json)
      assert chart.name == "produce-rate"
      assert chart.points == [%{label: "v0.28.1", value: 37_146}, %{label: "v0.28.2", value: nil}]
    end

    for {json, reason} <- [
          {"not json", "not valid JSON"},
          {"[1]", "is a JSON object"},
          {~s({"title": "t", "unit": "u", "points": [{"label": "a", "value": 1}]}), "needs a name"},
          {~s({"name": "Bad Name", "title": "t", "unit": "u", "points": [{"label": "a", "value": 1}]}),
           "lowercase letters"},
          {~s({"name": "x", "unit": "u", "points": [{"label": "a", "value": 1}]}), "needs a title"},
          {~s({"name": "x", "title": "", "unit": "u", "points": [{"label": "a", "value": 1}]}), "needs a title"},
          {~s({"name": "x", "title": "t", "points": [{"label": "a", "value": 1}]}), "needs a unit"},
          {~s({"name": "x", "title": "t", "unit": "u", "points": []}), "1 to 8 points"},
          {~s({"name": "x", "title": "t", "unit": "u", "points": [{"label": "a", "value": -1}]}), "at least zero"},
          {~s({"name": "x", "title": "t", "unit": "u", "points": [{"label": "a", "value": "1"}]}), "at least zero"},
          {~s({"name": "x", "title": "t", "unit": "u", "points": [{"value": 1}]}), "a label"},
          {~s({"name": "x", "title": "t", "unit": "u", "points": [{"label": "#{String.duplicate("a", 21)}", "value": 1}]}),
           "at most 20"},
          {~s({"name": "x", "title": "#{String.duplicate("t", 121)}", "unit": "u", "points": [{"label": "a", "value": 1}]}),
           "at most 120"}
        ] do
      test "refuses a chart whose problem is: #{reason} (#{:erlang.phash2(json)})" do
        assert {:error, message} = Chart.parse(unquote(json))
        assert message =~ unquote(reason)
      end
    end

    test "refuses more than 8 points" do
      points = Enum.map_join(1..9, ",", &~s({"label": "v#{&1}", "value": #{&1}}))
      assert {:error, message} = Chart.parse(~s({"name": "x", "title": "t", "unit": "u", "points": [#{points}]}))
      assert message =~ "1 to 8 points"
    end
  end

  describe "to_svg/1" do
    test "draws one bar per measured point and an outlined gap, never a zero bar, for a missing one" do
      {:ok, chart} = Chart.parse(@json)
      svg = Chart.to_svg(chart)
      assert svg =~ ~s(viewBox="0 0 1200 630")
      assert svg =~ "37,146"
      assert svg =~ "not measured"
      assert svg =~ ~s(stroke-dasharray="8 6")
      assert length(Regex.scan(~r/fill="#3b5bdb"/, svg)) == 1
    end

    test "every coloured element carries a chart- class the dark theme recolours, and keeps its light colour" do
      {:ok, chart} = Chart.parse(@json)
      svg = Chart.to_svg(chart)

      elements = Regex.scan(~r/<(?:rect|text|line)\b[^>]*>/, svg) |> List.flatten()
      assert elements != []

      for element <- elements, element =~ ~r/\b(?:fill|stroke)="#/ do
        assert element =~ ~r/\bclass="chart-[a-z-]+"/, "no chart- class on #{element}"
      end

      classes = Regex.scan(~r/class="(chart-[a-z-]+)"/, svg, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
      css = File.read!(Path.expand("../../../site/ui_kits/website/blog.css", __DIR__))

      for class <- classes do
        assert css =~ ~r/\.dark \.chart \S*\.#{class}\b/, "blog.css has no dark rule for .#{class}"
      end
    end

    test "holds no stylesheet and no CSS variable, so the PNG render draws it exactly as before" do
      {:ok, chart} = Chart.parse(@json)
      svg = Chart.to_svg(chart)
      refute svg =~ "<style"
      refute svg =~ "var("
      assert svg =~ ~s(fill="#ffffff")
    end

    test "escapes every text, so a title or a label can add no element" do
      {:ok, chart} =
        Chart.parse(
          ~s({"name": "x", "title": "<script>a&b</script>", "unit": "\\"u'", "points": [{"label": "<b>", "value": 1}]})
        )

      svg = Chart.to_svg(chart)
      refute svg =~ "<script>"
      refute svg =~ "<b>"
      assert svg =~ "&lt;script&gt;a&amp;b&lt;/script&gt;"
      assert svg =~ "&quot;u&#39;"
    end

    test "draws all-null and all-zero series without dividing by zero" do
      for value <- ["null", "0"] do
        {:ok, chart} =
          Chart.parse(~s({"name": "x", "title": "t", "unit": "u", "points": [{"label": "a", "value": #{value}}]}))

        assert Chart.to_svg(chart) =~ "</svg>"
      end
    end
  end

  test "hash/1 is of the trimmed JSON, so the image's name follows the data and not the drawing" do
    {:ok, chart} = Chart.parse(@json)
    assert Chart.hash(@json) == Chart.hash("\n" <> @json <> "\n  ")
    assert Chart.hash(@json) =~ ~r/\A[0-9a-f]{8}\z/
    refute Chart.hash(@json) == Chart.hash(String.replace(@json, "37146", "37147"))
    assert Chart.png_name(chart, @json) == "produce-rate-#{Chart.hash(@json)}.png"
  end

  test "format_value/1 groups thousands and keeps one decimal for a fraction" do
    assert Chart.format_value(0) == "0"
    assert Chart.format_value(999) == "999"
    assert Chart.format_value(1_234_567) == "1,234,567"
    assert Chart.format_value(2617.0) == "2,617"
    assert Chart.format_value(68.55) == "68.5" or Chart.format_value(68.55) == "68.6"
  end

  test "size/0 is the PNG's size" do
    assert Chart.size() == {1200, 630}
  end
end
