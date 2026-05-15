defmodule RhoWeb.DataTable.StreamsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias RhoWeb.DataTable.Streams

  describe "group ids" do
    test "builds deterministic slugged ids without dynamic atoms" do
      assert Streams.group_id_for("People & Culture") == "grp-people-culture"
      assert Streams.group_id_for("Core", "Level 1+") == "grp-core-level-1"
      assert Streams.slug_fragment(:unexpected) == "unknown"
    end
  end

  describe "build_stream_items/3" do
    test "marks parent rows when panel mode is disabled" do
      assert Streams.build_stream_items([%{id: "1"}], false, MapSet.new()) == [
               %{id: "1", _kind: :parent}
             ]
    end

    test "adds panel rows only for expanded rows in panel mode" do
      rows = [%{id: "1"}, %{id: "2"}]
      collapsed = MapSet.new(["row-2"])

      assert Streams.build_stream_items(rows, true, collapsed) == [
               %{id: "1", _kind: :parent},
               %{id: "1", _kind: :panel},
               %{id: "2", _kind: :parent}
             ]
    end
  end

  test "lookup_group_rows/2 finds flat and nested leaf groups" do
    flat_rows = [%{id: "a"}]
    nested_rows = [%{id: "b"}]

    grouped = [
      {"Core", {:rows, flat_rows}},
      {"Advanced", {:nested, [{"Level 2", nested_rows}]}}
    ]

    assert Streams.lookup_group_rows(grouped, "grp-core") == flat_rows
    assert Streams.lookup_group_rows(grouped, "grp-advanced-level-2") == nested_rows
    assert Streams.lookup_group_rows(grouped, "grp-missing") == []
  end

  test "more_pages?/2 checks loaded count against total" do
    streamed = %{
      "grp-a" => %{loaded: 10, total: 11},
      "grp-b" => %{loaded: 11, total: 11}
    }

    assert Streams.more_pages?(streamed, "grp-a")
    refute Streams.more_pages?(streamed, "grp-b")
    refute Streams.more_pages?(streamed, "grp-missing")
  end

  test "stream_for_row/2 resolves rows to already-assigned streams" do
    socket = %Socket{
      assigns: %{
        _group_to_stream: %{
          "grp-domain-cluster" => :_dt_rows_0,
          "grp-domain" => :_dt_rows_1
        }
      }
    }

    assert Streams.stream_for_row(socket, %{category: "Domain", cluster: "Cluster"}) ==
             {:ok, :_dt_rows_0}

    assert Streams.stream_for_row(socket, %{category: "Domain"}) == {:ok, :_dt_rows_1}
    assert Streams.stream_for_row(socket, %{category: "Other"}) == :none
  end

  test "stream_name_for_group/2 allocates stable atoms from a fixed pool" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    {socket, first} = Streams.stream_name_for_group(socket, "grp-a")
    {socket, second} = Streams.stream_name_for_group(socket, "grp-b")
    {_socket, first_again} = Streams.stream_name_for_group(socket, "grp-a")

    assert first == :_dt_rows_0
    assert second == :_dt_rows_1
    assert first_again == first
  end
end
