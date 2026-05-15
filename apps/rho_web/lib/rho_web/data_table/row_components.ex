defmodule RhoWeb.DataTable.RowComponents do
  @moduledoc """
  Row and cell function components for `RhoWeb.DataTableComponent`.
  """

  use Phoenix.Component

  alias RhoWeb.DataTable.Rows
  alias RhoWeb.DataTable.Streams

  def parent_row(assigns) do
    row_id_str = to_string(Rows.row_id(assigns.row))

    expanded? =
      assigns.has_children and not Streams.collapsed?(assigns.collapsed, "row-" <> row_id_str)

    children =
      if assigns.has_children do
        Map.get(assigns.row, assigns.children_key) ||
          Map.get(assigns.row, to_string(assigns.children_key)) || []
      else
        []
      end

    selected? = MapSet.member?(assigns.selected_ids, row_id_str)

    assigns =
      assign(assigns,
        row_id_str: row_id_str,
        expanded?: expanded?,
        children: children,
        selected?: selected?
      )

    ~H"""
    <%= if @has_children do %>
      <tr id={@dom_id} class={[
        "dt-row dt-parent-row",
        @expanded? && @panel_mode && "dt-skill-expanded",
        @selected? && "dt-row-selected"
      ]}>
        <.row_select_cell row_id={@row_id_str} selected?={@selected?} myself={@myself} />
        <td class="dt-td dt-td-expand" phx-click="toggle_group" phx-target={@myself} phx-value-group={"row-" <> @row_id_str}>
          <span class={"dt-chevron" <> if(@expanded?, do: " dt-expanded", else: "")}></span>
        </td>
        <td :if={@show_id} class="dt-td dt-td-id"><%= @row_id_str %></td>
        <td class="dt-td dt-td-source">
          <.provenance_badge source={get_cell(@row, :_source)} />
        </td>
        <.editable_cell :for={col <- @visible_columns} row={@row} col={col} editing={@editing} myself={@myself} row_id={@row_id_str} metadata={@metadata} />
        <%= if !@panel_mode do %>
          <td :for={_col <- @child_columns} class="dt-td dt-td-empty"></td>
        <% else %>
          <td class="dt-td dt-col-levels"><%= length(@children) %></td>
        <% end %>
        <td class="dt-td dt-td-row-actions">
          <.delete_button row_id={@row_id_str} confirm_delete={@confirm_delete} myself={@myself} />
        </td>
      </tr>
    <% else %>
      <tr id={@dom_id} class={["dt-row", @selected? && "dt-row-selected"]}>
        <.row_select_cell row_id={@row_id_str} selected?={@selected?} myself={@myself} />
        <td :if={@show_id} class="dt-td dt-td-id"><%= @row_id_str %></td>
        <td class="dt-td dt-td-source">
          <.provenance_badge source={get_cell(@row, :_source)} />
        </td>
        <.editable_cell :for={col <- @visible_columns} row={@row} col={col} editing={@editing} myself={@myself} row_id={@row_id_str} metadata={@metadata} />
        <td class="dt-td dt-td-row-actions">
          <.delete_button row_id={@row_id_str} confirm_delete={@confirm_delete} myself={@myself} />
        </td>
      </tr>
    <% end %>
    """
  end

  def row_select_cell(assigns) do
    ~H"""
    <td class="dt-td dt-td-select" phx-click="toggle_row_selection" phx-target={@myself} phx-value-row-id={@row_id}>
      <input
        type="checkbox"
        class="dt-row-checkbox"
        checked={@selected?}
        aria-label={"Select row " <> @row_id}
        tabindex="-1"
      />
    </td>
    """
  end

  def proficiency_panel_row(assigns) do
    row_id_str = to_string(Rows.row_id(assigns.row))

    children =
      Map.get(assigns.row, assigns.children_key) ||
        Map.get(assigns.row, to_string(assigns.children_key)) || []

    assigns = assign(assigns, row_id_str: row_id_str, children: children)

    ~H"""
    <tr id={@dom_id} class="dt-row dt-proficiency-row">
      <td colspan={@panel_colspan} style="padding: 0;">
        <div :if={@children != []} class="dt-proficiency-panel">
          <%= for {child, idx} <- @children |> Enum.with_index() |> Enum.sort_by(fn {c, _} -> get_child_level(c) end) do %>
            <% child_id = @row_id_str <> ":child:" <> to_string(idx) %>
            <div class="dt-proficiency-item">
              <span class="dt-proficiency-level">L<%= get_child_level(child) %></span>
              <.inline_editable_span id={child_id} field="level_name" value={get_cell(child, :level_name)} editing={@editing} myself={@myself} class="dt-proficiency-name" />
              <.inline_editable_span id={child_id} field="level_description" value={get_cell(child, :level_description)} editing={@editing} myself={@myself} class="dt-proficiency-desc" multiline?={true} />
              <button type="button" class="dt-child-delete-btn" phx-click="delete_child" phx-target={@myself} phx-value-parent-id={@row_id_str} phx-value-index={idx} title="Remove level">
                &times;
              </button>
            </div>
          <% end %>
        </div>
        <div class="dt-proficiency-add">
          <button type="button" class="dt-add-child-btn" phx-click="add_child" phx-target={@myself} phx-value-parent-id={@row_id_str}>
            + Add Level
          </button>
        </div>
      </td>
    </tr>
    """
  end

  attr(:source, :any, default: nil)

  def provenance_badge(assigns) do
    {label, title, klass} = badge_for(assigns.source)
    assigns = assign(assigns, label: label, title: title, klass: klass)

    ~H"""
    <span :if={@label} class={"dt-source-badge " <> @klass} title={@title}><%= @label %></span>
    """
  end

  def editable_cell(assigns) do
    row_id = assigns.row_id
    editing? = assigns.editing == {row_id, Atom.to_string(assigns.col.key)}
    value = get_cell(assigns.row, assigns.col.key)

    assigns = assign(assigns, editing?: editing?, value: value, cell_row_id: row_id)

    ~H"""
    <%= if @col.type == :action do %>
      <.action_cell row={@row} col={@col} value={@value} row_id={@cell_row_id} myself={@myself} />
    <% else %>
    <td
      class={"dt-td " <> (@col.css_class || "dt-td-#{@col.key}")}
      phx-click={if @col.editable, do: "start_edit"}
      phx-target={@myself}
      phx-value-id={@cell_row_id}
      phx-value-field={@col.key}
    >
      <%= if @editing? do %>
        <form phx-submit="save_edit" phx-target={@myself}>
          <input type="hidden" name="row_id" value={@cell_row_id} />
          <input type="hidden" name="field" value={@col.key} />
          <%= if @col.type == :textarea do %>
            <textarea
              name="value"
              class="dt-cell-input"
              phx-hook="AutoFocus"
              id={"edit-#{@cell_row_id}-#{@col.key}"}
              phx-keydown="cancel_edit"
              phx-target={@myself}
              phx-key="Escape"
              phx-blur="save_edit"
              phx-target={@myself}
              phx-value-row_id={@cell_row_id}
              phx-value-field={@col.key}
            ><%= @value %></textarea>
          <% else %>
            <input
              type={if @col.type == :number, do: "number", else: "text"}
              name="value"
              value={@value}
              class="dt-cell-input"
              phx-hook="AutoFocus"
              id={"edit-#{@cell_row_id}-#{@col.key}"}
              phx-blur="save_edit"
              phx-target={@myself}
              phx-value-row_id={@cell_row_id}
              phx-value-field={@col.key}
              phx-keydown="cancel_edit"
              phx-target={@myself}
              phx-key="Escape"
            />
          <% end %>
        </form>
      <% else %>
        <%= if @col.key == :skill_name && !@col.editable && @metadata[:library_id] do %>
          <span
            class="dt-cell-text dt-cell-link"
            phx-click="navigate_to_library"
            phx-target={@myself}
            phx-value-library-id={@metadata[:library_id]}
          ><%= @value %></span>
        <% else %>
          <span class="dt-cell-text"><%= @value %></span>
        <% end %>
      <% end %>
    </td>
    <% end %>
    """
  end

  def action_cell(assigns) do
    resolved = assigns.value not in [nil, "", "unresolved"]
    assigns = assign(assigns, resolved: resolved)

    ~H"""
    <td class={"dt-td " <> (@col.css_class || "dt-td-action")}>
      <%= if @resolved do %>
        <span class="dt-resolution-badge">
          <span class="dt-resolution-icon">&#10003;</span>
          <span class="dt-resolution-label"><%= resolution_label(@value) %></span>
        </span>
      <% else %>
        <div class="dt-action-buttons">
          <button
            type="button"
            class="dt-action-btn dt-action-merge-a"
            phx-click="resolve_conflict"
            phx-target={@myself}
            phx-value-id={@row_id}
            phx-value-resolution="merge_a"
            title="Keep Skill A, absorb B's levels"
          >&#8592; A</button>
          <button
            type="button"
            class="dt-action-btn dt-action-merge-b"
            phx-click="resolve_conflict"
            phx-target={@myself}
            phx-value-id={@row_id}
            phx-value-resolution="merge_b"
            title="Keep Skill B, absorb A's levels"
          >B &#8594;</button>
          <button
            type="button"
            class="dt-action-btn dt-action-keep-both"
            phx-click="resolve_conflict"
            phx-target={@myself}
            phx-value-id={@row_id}
            phx-value-resolution="keep_both"
            title="Keep both as separate skills"
          >Both</button>
        </div>
      <% end %>
    </td>
    """
  end

  def inline_editable_span(assigns) do
    editing? = assigns.editing == {assigns.id, assigns.field}

    assigns =
      assigns
      |> assign(:editing?, editing?)
      |> assign_new(:multiline?, fn -> false end)

    ~H"""
    <%= if @editing? do %>
      <form phx-submit="save_edit" phx-target={@myself} class={@class}>
        <input type="hidden" name="row_id" value={@id} />
        <input type="hidden" name="field" value={@field} />
        <%= if @multiline? do %>
          <textarea
            name="value"
            class="dt-cell-input dt-inline-input dt-inline-textarea"
            phx-hook="Autosize"
            id={"edit-#{@id}-#{@field}"}
            phx-blur="save_edit"
            phx-target={@myself}
            phx-value-row_id={@id}
            phx-value-field={@field}
            phx-keydown="cancel_edit"
            phx-target={@myself}
            phx-key="Escape"
            rows="3"
          ><%= @value %></textarea>
        <% else %>
          <input
            type="text"
            name="value"
            value={@value}
            class="dt-cell-input dt-inline-input"
            phx-hook="AutoFocus"
            id={"edit-#{@id}-#{@field}"}
            phx-blur="save_edit"
            phx-target={@myself}
            phx-value-row_id={@id}
            phx-value-field={@field}
            phx-keydown="cancel_edit"
            phx-target={@myself}
            phx-key="Escape"
          />
        <% end %>
      </form>
    <% else %>
      <span
        class={@class <> " dt-editable-hint"}
        phx-click="start_edit"
        phx-target={@myself}
        phx-value-id={@id}
        phx-value-field={@field}
      >
        <%= @value %>
      </span>
    <% end %>
    """
  end

  def delete_button(assigns) do
    ~H"""
    <%= if @confirm_delete == @row_id do %>
      <span class="dt-delete-confirm">
        <span class="dt-delete-confirm-text">Delete?</span>
        <button type="button" class="dt-delete-yes" phx-click="delete_row" phx-target={@myself} phx-value-id={@row_id}>Yes</button>
        <button type="button" class="dt-delete-no" phx-click="cancel_delete" phx-target={@myself}>No</button>
      </span>
    <% else %>
      <button type="button" class="dt-row-delete-btn" phx-click="confirm_delete" phx-target={@myself} phx-value-id={@row_id} title="Delete row">
        &times;
      </button>
    <% end %>
    """
  end

  def add_row_in_group(assigns) do
    group_by = assigns.group_by

    add_params =
      case {group_by, assigns.group_label, assigns.sub_label} do
        {[field1, field2 | _], label1, label2} when not is_nil(label2) ->
          %{to_string(field1) => label1, to_string(field2) => label2}

        {[field1 | _], label1, _} ->
          %{to_string(field1) => label1}

        _ ->
          %{}
      end

    assigns = assign(assigns, :add_params, add_params)

    ~H"""
    <div class="dt-group-add-row">
      <button type="button" class="dt-add-row-inline" phx-click="add_row" phx-target={@myself}
        {Enum.map(@add_params, fn {k, v} -> {"phx-value-#{k}", v} end)}>
        + Add Row
      </button>
    </div>
    """
  end

  defp get_cell(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key)) || ""
  end

  defp get_child_level(child) do
    (Rho.MapAccess.get(child, :level) || 0)
    |> to_integer()
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
  defp to_integer(_), do: 0

  defp badge_for(s) when s in [:user, "user"], do: {"U", "Edited by user", "dt-source-user"}
  defp badge_for(s) when s in [:flow, "flow"], do: {"F", "Written by flow", "dt-source-flow"}
  defp badge_for(s) when s in [:agent, "agent"], do: {"A", "Written by agent", "dt-source-agent"}
  defp badge_for(_), do: {nil, nil, nil}

  defp resolution_label("merge_a"), do: "Keep A"
  defp resolution_label("merge_b"), do: "Keep B"
  defp resolution_label("keep_both"), do: "Keep Both"
  defp resolution_label(other), do: other
end
