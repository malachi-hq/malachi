defmodule Malachi.Purge.PointsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Malachi.Purge.Points

  doctest Points

  @root {"t", 0}
  @left {"t", 1}
  @right {"t", 2}

  defp sealed(start, length, sealed_at),
    do: %{state: :sealed, start_offset: start, length: length, sealed_at: sealed_at}

  defp active(start), do: %{state: :active, start_offset: start, length: nil, sealed_at: nil}

  defp range(id, parents, state, extra \\ %{}), do: Map.merge(%{id: id, parents: parents, state: state}, extra)

  # A root of 10 offsets in two sealed segments, split into two active children.
  defp split_view(root_extra \\ %{}) do
    %{
      ranges: %{
        @root => range(@root, [], :sealed, root_extra),
        @left => range(@left, [@root], :active),
        @right => range(@right, [@root], :active)
      },
      segments: %{
        @root => [sealed(0, 4, 100), sealed(4, 6, 200)],
        @left => [sealed(0, 3, 300), active(3)],
        @right => [active(0)]
      }
    }
  end

  describe "before_time/2" do
    test "moves each range to the end of its oldest segments sealed by then, ancestors included" do
      assert Points.before_time(split_view(), 150) == %{@root => 4}
      assert Points.before_time(split_view(), 250) == %{@root => 10}
      assert Points.before_time(split_view(), 300) == %{@root => 10, @left => 3}
    end

    test "never reaches into the active segment, and nothing before the first seal" do
      assert Points.before_time(split_view(), 99) == %{}
      assert Points.before_time(split_view(), 10_000)[@right] == nil
    end

    test "a segment sealed later than a newer one stops the run (clock skew between leaders)" do
      view = %{
        ranges: %{@root => range(@root, [], :active)},
        segments: %{@root => [sealed(0, 2, 100), sealed(2, 2, 900), sealed(4, 2, 150)]}
      }

      assert Points.before_time(view, 500) == %{@root => 2}
    end

    test "leaves out a range already purged at or past the point" do
      assert Points.before_time(split_view(%{logical_start: 4}), 150) == %{}
      assert Points.before_time(split_view(%{logical_start: 4}), 250) == %{@root => 10}
    end

    test "a range with no segment is left out" do
      view = %{ranges: %{@root => range(@root, [], :active)}, segments: %{}}
      assert Points.before_time(view, 1_000) == %{}
    end
  end

  describe "at_position/3" do
    test "a position on the issuer's own records moves only the issuer" do
      assert Points.at_position(split_view(), @left, {1, 2}) == {:ok, %{@left => 2}}
    end

    test "a position still inside an ancestor is refused: the siblings read it too" do
      assert Points.at_position(split_view(), @left, {0, 5}) == {:error, :cursor_in_ancestor}
    end

    test "a position the root handed out before it was split is refused: its records are an ancestor's now" do
      assert Points.at_position(split_view(), @root, {0, 5}) == {:error, :cursor_in_ancestor}
    end

    test "a source the issuer's history does not have, or an unknown issuer, is an invalid position" do
      assert Points.at_position(split_view(), @left, {2, 0}) == {:error, :invalid_position}
      assert Points.at_position(split_view(), {"t", 99}, {0, 0}) == {:error, :invalid_position}
    end

    test "a position at or below the current start moves nothing" do
      assert Points.at_position(split_view(), @left, {1, 0}) == {:ok, %{}}
    end
  end

  describe "floors/2 (one group's low-water mark through the lineage)" do
    test "the ancestor takes the least any child has read of it" do
      assert Points.floors(split_view(), %{@left => {0, 7}, @right => {0, 3}}) == %{@root => 3}
    end

    test "a child past the ancestor has read it to its sealed end" do
      assert Points.floors(split_view(), %{@left => {1, 2}, @right => {1, 0}}) == %{@root => 10, @left => 2}
    end

    test "a child with no commit pins the ancestor at 0" do
      assert Points.floors(split_view(), %{@left => {1, 2}}) == %{@left => 2}
    end

    test "an ancestor with no sealed segment left has no end to move to" do
      view = put_in(split_view().segments[@root], [])
      assert Points.floors(view, %{@left => {1, 2}, @right => {1, 1}}) == %{@left => 2, @right => 1}
    end

    test "a deeper lineage resolves every ancestor" do
      grandchild = {"t", 3}
      sibling = {"t", 4}

      view = %{
        ranges: %{
          @root => range(@root, [], :sealed),
          @left => range(@left, [@root], :sealed),
          @right => range(@right, [@root], :active),
          grandchild => range(grandchild, [@root, @left], :active),
          sibling => range(sibling, [@root, @left], :active)
        },
        segments: %{@root => [sealed(0, 10, 1)], @left => [sealed(0, 6, 2)]}
      }

      commits = %{@right => {1, 0}, grandchild => {2, 4}, sibling => {1, 5}}
      assert Points.floors(view, commits) == %{@root => 10, @left => 5, grandchild => 4}
    end

    test "a sealed topic (no active range) moves nothing" do
      view = %{ranges: %{@root => range(@root, [], :sealed)}, segments: %{@root => [sealed(0, 4, 1)]}}
      assert Points.floors(view, %{@root => {0, 4}}) == %{}
    end
  end

  property "an ancestor's floor never passes what any active descendant has read of it" do
    check all(
            left_at <- position(),
            right_at <- position(),
            committed <- list_of(member_of([@left, @right]), max_length: 2),
            max_runs: 200
          ) do
      positions = %{@left => left_at, @right => right_at}
      commits = Map.take(positions, committed)
      floors = Points.floors(split_view(), commits)

      for {child, at} <- positions do
        read_of_root =
          cond do
            not Map.has_key?(commits, child) -> 0
            elem(at, 0) == 0 -> elem(at, 1)
            true -> 10
          end

        assert Map.get(floors, @root, 0) <= read_of_root
      end

      for {child, {1, offset}} <- commits, offset > 0, do: assert(floors[child] == offset)
    end
  end

  defp position, do: tuple({integer(0..1), integer(0..10)})
end
