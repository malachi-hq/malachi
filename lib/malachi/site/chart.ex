defmodule Malachi.Site.Chart do
  @moduledoc """
  A bar chart of one measurement across releases, drawn as inline SVG with no dependency, in the manner of
  `benchmark/dashboard/index.html` (issue #373).

  A blog post holds a chart as a fenced block whose info string is `malachi-chart` and whose body is JSON:

      {"name": "produce-rate", "title": "Produce rate, Node.js load test", "unit": "records/s",
       "points": [{"label": "v0.28.1", "value": 37146}, {"label": "v0.28.2", "value": null}]}

  The numbers are frozen in the post when it is generated, so a post shows what was measured when it was
  written, and nothing redraws it later from newer files. A `null` value is a release with no measurement of
  its code: it is drawn as an outlined gap, never as zero, since a bar at zero reads as a measured zero.

  The same chart is also published as a PNG for the places that do not render inline SVG (dev.to, Medium,
  LinkedIn). Its file is `<name>-<hash>.png` beside the post, where the hash is `hash/1` of the block's JSON
  text: a post whose numbers change needs a new image, and the site check reports the old one as stale. The
  hash is of the data rather than of the SVG, so restyling the chart does not invalidate every published image.
  """

  @width 1200
  @height 630
  @max_points 8
  @name ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/

  @typedoc "A chart read from a post's block."
  @type t :: %{
          name: String.t(),
          title: String.t(),
          unit: String.t(),
          points: [%{label: String.t(), value: number() | nil}]
        }

  @doc "The width and height of the chart, which are also the PNG's."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  @doc "The image's hash: the first 8 hex digits of the SHA-256 of the block's JSON, trimmed."
  @spec hash(String.t()) :: String.t()
  def hash(json) do
    :sha256 |> :crypto.hash(String.trim(json)) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  @doc "The PNG's file name for a chart and its block's JSON."
  @spec png_name(t(), String.t()) :: String.t()
  def png_name(%{name: name}, json), do: "#{name}-#{hash(json)}.png"

  @doc """
  Reads a block's JSON into a chart, or says what is wrong with it: the name (lowercase letters, digits and
  dashes, at most 40), a title and a unit, and 1 to #{@max_points} points, each a label and a value that is a
  number at least zero or null.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(json) do
    with {:ok, %{} = data} <- decode(json),
         {:ok, name} <- name(data["name"]),
         {:ok, title} <- text(data, "title", 120),
         {:ok, unit} <- text(data, "unit", 30),
         {:ok, points} <- points(data["points"]) do
      {:ok, %{name: name, title: title, unit: unit, points: points}}
    else
      {:ok, _not_an_object} -> {:error, "a chart is a JSON object"}
      {:error, _} = error -> error
    end
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, "a chart's block is not valid JSON"}
    end
  end

  defp name(name) when is_binary(name) do
    if Regex.match?(@name, name),
      do: {:ok, name},
      else: {:error, "a chart's name is lowercase letters, digits and dashes, got #{inspect(name)}"}
  end

  defp name(other), do: {:error, "a chart needs a name, got #{inspect(other)}"}

  defp text(data, key, max) do
    case data[key] do
      value when is_binary(value) and value != "" ->
        if String.length(value) <= max,
          do: {:ok, value},
          else: {:error, "a chart's #{key} is at most #{max} characters"}

      other ->
        {:error, "a chart needs a #{key}, got #{inspect(other)}"}
    end
  end

  defp points(points) when is_list(points) and points != [] and length(points) <= @max_points do
    points
    |> Enum.map(&point/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, point}, {:ok, acc} -> {:cont, {:ok, [point | acc]}}
      {:error, _} = error, _ -> {:halt, error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp points(_other), do: {:error, "a chart has 1 to #{@max_points} points"}

  defp point(%{"label" => label, "value" => value})
       when is_binary(label) and label != "" and (is_nil(value) or (is_number(value) and value >= 0)) do
    if String.length(label) <= 20,
      do: {:ok, %{label: label, value: value}},
      else: {:error, "a point's label is at most 20 characters"}
  end

  defp point(other), do: {:error, "a point is a label and a value at least zero or null, got #{inspect(other)}"}

  @doc """
  The chart as an SVG document. Every text in it is escaped, so a label or a title is drawn as written and can
  add no element.
  """
  @spec to_svg(t()) :: String.t()
  def to_svg(%{title: title, unit: unit, points: points}) do
    {left, right, top, bottom} = {96, 48, 112, 96}
    plot_w = @width - left - right
    plot_h = @height - top - bottom
    max = points |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)
    slot = plot_w / length(points)
    bar_w = slot * 0.6
    base_y = top + plot_h

    bars =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, i} ->
        x = left + i * slot + (slot - bar_w) / 2
        center = x + bar_w / 2
        bar(point, x, center, bar_w, base_y, plot_h, max)
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{@height}" width="#{@width}" height="#{@height}" role="img" aria-label="#{escape(title)}">
    <title>#{escape(title)}</title>
    <rect width="#{@width}" height="#{@height}" fill="#ffffff"/>
    <text x="#{left}" y="56" font-family="system-ui, sans-serif" font-size="34" font-weight="700" fill="#111827">#{escape(title)}</text>
    <text x="#{left}" y="92" font-family="system-ui, sans-serif" font-size="22" fill="#4b5563">#{escape(unit)}</text>
    <line x1="#{left}" y1="#{base_y}" x2="#{@width - right}" y2="#{base_y}" stroke="#d1d5db" stroke-width="2"/>
    #{Enum.join(bars, "\n")}
    </svg>
    """
  end

  defp bar(%{label: label, value: nil}, x, center, bar_w, base_y, plot_h, _max) do
    h = plot_h * 0.25

    """
    <rect x="#{num(x)}" y="#{num(base_y - h)}" width="#{num(bar_w)}" height="#{num(h)}" fill="none" stroke="#9ca3af" stroke-width="2" stroke-dasharray="8 6"/>
    <text x="#{num(center)}" y="#{num(base_y - h - 14)}" text-anchor="middle" font-family="system-ui, sans-serif" font-size="20" fill="#6b7280">not measured</text>
    #{label_text(label, center, base_y)}
    """
  end

  defp bar(%{label: label, value: value}, x, center, bar_w, base_y, plot_h, max) do
    h = if max > 0, do: plot_h * value / max, else: 0

    """
    <rect x="#{num(x)}" y="#{num(base_y - h)}" width="#{num(bar_w)}" height="#{num(h)}" rx="4" fill="#3b5bdb"/>
    <text x="#{num(center)}" y="#{num(base_y - h - 14)}" text-anchor="middle" font-family="system-ui, sans-serif" font-size="22" font-weight="600" fill="#111827">#{escape(format_value(value))}</text>
    #{label_text(label, center, base_y)}
    """
  end

  defp label_text(label, center, base_y) do
    ~s(<text x="#{num(center)}" y="#{num(base_y + 40)}" text-anchor="middle" font-family="system-ui, sans-serif" font-size="22" fill="#374151">#{escape(label)}</text>)
  end

  @doc "A value as the chart prints it: an integer with thousands separators, anything else to one decimal."
  @spec format_value(number()) :: String.t()
  def format_value(value) when is_integer(value), do: Malachi.ResultsText.group_digits(value)

  def format_value(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15,
      do: format_value(trunc(value)),
      else: :erlang.float_to_binary(value, decimals: 1)
  end

  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  @doc "Escapes text for an XML or HTML text node or a double-quoted attribute."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
