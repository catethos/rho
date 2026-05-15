defmodule RhoWeb.WorkbenchDisplay do
  @moduledoc """
  Display-state reducer for the Workbench surface.

  The data-table server owns rows and table snapshots. This module owns
  the user-facing choice of Workbench home versus a table editor.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.DataTable.Tabs
  alias RhoWeb.Session.SignalRouter

  defstruct mode: :home,
            active_table: nil,
            open_tables: [],
            loading_tables: MapSet.new(),
            error: nil

  @type mode :: :home | {:table, String.t()}

  @type t :: %__MODULE__{
          mode: mode(),
          active_table: String.t() | nil,
          open_tables: [String.t()],
          loading_tables: MapSet.t(String.t()),
          error: term() | nil
        }

  @doc "Build display state from a data-table projection-like map."
  def from_data_state(state, mode \\ nil) when is_map(state) do
    open_tables = Tabs.display_order(state[:table_order] || [], state[:tables] || [])
    active_table = state[:active_table]

    mode =
      cond do
        mode in [:home] -> :home
        match?({:table, table} when is_binary(table), mode) -> mode
        is_binary(active_table) and active_table in open_tables -> {:table, active_table}
        true -> :home
      end

    %__MODULE__{
      mode: mode,
      active_table: active_table,
      open_tables: open_tables,
      error: state[:error]
    }
  end

  @doc "Workbench home is visible when display mode says home, or for legacy natural-home data."
  def home?(%__MODULE__{mode: :home}, _data_state), do: true
  def home?(%__MODULE__{}, _data_state), do: false

  def home?(display, data_state) when is_map(display) do
    display
    |> normalize(data_state)
    |> home?(data_state)
  end

  def home?(nil, _data_state), do: false

  def for_render(%__MODULE__{} = display, _data_state, _natural_home?), do: display

  def for_render(display, data_state, natural_home?) when is_map(display) do
    display
    |> normalize(data_state)
    |> for_render(data_state, natural_home?)
  end

  def for_render(nil, data_state, true), do: from_data_state(data_state, :home)

  def for_render(nil, %{active_table: table} = data_state, _natural_home?)
      when is_binary(table) and table != "main" do
    from_data_state(data_state, {:table, table})
  end

  def for_render(nil, data_state, _natural_home?), do: from_data_state(data_state)

  def return_available?(%__MODULE__{mode: :home}, data_state) do
    data_state
    |> Map.get(:table_order, [])
    |> Enum.any?(&(&1 != "main"))
  end

  def return_available?(_, _data_state), do: false

  @doc "The default table is a backing scratch table and cannot be closed from the Workbench."
  def closable_table?("main"), do: false
  def closable_table?(name) when is_binary(name), do: true
  def closable_table?(_), do: false

  @doc "Pick the next visible table after a close, preferring non-main artifacts."
  def fallback_table(data_state) when is_map(data_state) do
    order = Tabs.display_order(data_state[:table_order] || [], data_state[:tables] || [])

    Enum.find(order, &(&1 != "main")) || Enum.find(order, &(&1 == "main")) || "main"
  end

  @doc "Return the display mode after a table has been closed."
  def mode_after_close(data_state, closed_table) when is_map(data_state) do
    remaining =
      data_state
      |> Map.update(:table_order, [], &List.delete(&1, closed_table))
      |> Map.update(:tables, [], fn tables ->
        Enum.reject(tables, fn table -> table_name(table) == closed_table end)
      end)
      |> Tabs.display_order_for_state()

    case Enum.find(remaining, &(&1 != "main")) || Enum.find(remaining, &(&1 == "main")) do
      nil -> :home
      "main" -> :home
      name -> {:table, name}
    end
  end

  @doc "Set the socket display mode to Workbench home, preserving the legacy assign."
  def show_home(socket) do
    data_state = read_data_state(socket)

    socket
    |> assign(:workbench_display, from_data_state(data_state, :home))
    |> assign(:workbench_home_open?, true)
  end

  @doc "Set the socket display mode to an active table, preserving the legacy assign."
  def show_table(socket, table_name) when is_binary(table_name) do
    data_state = read_data_state(socket)

    display =
      data_state
      |> Map.put(:active_table, table_name)
      |> from_data_state({:table, table_name})

    socket
    |> assign(:workbench_display, display)
    |> assign(:workbench_home_open?, false)
  end

  def hide_home(socket) do
    data_state = read_data_state(socket)
    show_table(socket, data_state[:active_table] || "main")
  end

  def refresh_from_tables(socket, data_state) when is_map(data_state) do
    current = socket.assigns[:workbench_display]
    open_tables = Tabs.display_order(data_state[:table_order] || [], data_state[:tables] || [])

    mode =
      case current do
        %__MODULE__{mode: :home} -> :home
        %__MODULE__{mode: {:table, table}} -> if table in open_tables, do: {:table, table}
        _ -> nil
      end

    assign(socket, :workbench_display, from_data_state(data_state, mode))
  end

  defp normalize(%__MODULE__{} = display, _data_state), do: display

  defp normalize(display, data_state) when is_map(display),
    do: struct(__MODULE__, display) |> normalize(data_state)

  defp normalize(_, data_state), do: from_data_state(data_state)

  defp read_data_state(socket) do
    SignalRouter.read_ws_state(socket, :data_table) ||
      RhoWeb.Projections.DataTableProjection.init()
  end

  defp table_name(%{name: name}), do: name
  defp table_name(%{"name" => name}), do: name
  defp table_name(_), do: nil
end
