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

  def research_note_row(assigns) do
    row_id_str = to_string(Rows.row_id(assigns.row))
    selected? = MapSet.member?(assigns.selected_ids, row_id_str)

    fact = get_cell(assigns.row, :fact)
    source_title = get_cell(assigns.row, :source_title)
    source = get_cell(assigns.row, :source)
    published_date = get_cell(assigns.row, :published_date)
    tag = get_cell(assigns.row, :tag)
    relevance = get_cell(assigns.row, :relevance)
    pinned = get_cell(assigns.row, :pinned)

    assigns =
      assign(assigns,
        row_id_str: row_id_str,
        selected?: selected?,
        fact: fact,
        fact_blocks: research_fact_blocks(fact),
        source_title: source_title,
        source: source,
        source_href: external_href(source),
        source_label: research_source_label(source_title, source),
        source_domain: research_source_domain(source),
        published_date: published_date,
        tag: tag,
        relevance_label: research_relevance_label(relevance),
        pinned?: truthy?(pinned),
        editing_fact?: assigns.editing == {row_id_str, "fact"},
        editing_source_title?: assigns.editing == {row_id_str, "source_title"},
        editing_source?: assigns.editing == {row_id_str, "source"}
      )

    ~H"""
    <tr id={@dom_id} class={["dt-row dt-research-row", @selected? && "dt-row-selected", @pinned? && "dt-research-row-pinned"]}>
      <.row_select_cell row_id={@row_id_str} selected?={@selected?} myself={@myself} />
      <td class="dt-td dt-td-source">
        <.provenance_badge source={get_cell(@row, :_source)} />
      </td>
      <td class="dt-td dt-research-note-cell">
        <%= if @editing_fact? do %>
          <.research_edit_form row_id={@row_id_str} field="fact" value={@fact} multiline?={true} myself={@myself} />
        <% else %>
          <div class="dt-research-note-head">
            <span :if={@pinned?} class="dt-research-pin-badge">Pinned</span>
            <button
              type="button"
              class="dt-research-edit"
              phx-click="start_edit"
              phx-target={@myself}
              phx-value-id={@row_id_str}
              phx-value-field="fact"
              title="Edit finding"
            >Edit</button>
          </div>
          <.research_fact_view blocks={@fact_blocks} />
        <% end %>
      </td>
      <td class="dt-td dt-research-meta-cell">
        <div class="dt-research-source-title">
          <%= if @editing_source_title? do %>
            <.research_edit_form row_id={@row_id_str} field="source_title" value={@source_title} myself={@myself} />
          <% else %>
            <span
              phx-click="start_edit"
              phx-target={@myself}
              phx-value-id={@row_id_str}
              phx-value-field="source_title"
              title="Edit source title"
            ><%= @source_label %></span>
          <% end %>
        </div>
        <div class="dt-research-url">
          <%= if @editing_source? do %>
            <.research_edit_form row_id={@row_id_str} field="source" value={@source} myself={@myself} />
          <% else %>
            <%= if @source_href do %>
              <a href={@source_href} target="_blank" rel="noopener noreferrer"><%= @source_domain %></a>
              <button
                type="button"
                class="dt-research-url-edit"
                phx-click="start_edit"
                phx-target={@myself}
                phx-value-id={@row_id_str}
                phx-value-field="source"
                title="Edit source URL"
              >Edit URL</button>
            <% else %>
              <span
                phx-click="start_edit"
                phx-target={@myself}
                phx-value-id={@row_id_str}
                phx-value-field="source"
                title="Edit source"
              ><%= @source_domain %></span>
            <% end %>
          <% end %>
        </div>
        <div class="dt-research-chips">
          <span :if={@published_date != ""} class="dt-research-chip"><%= @published_date %></span>
          <span :if={@tag != ""} class="dt-research-chip"><%= @tag %></span>
          <span :if={@relevance_label != ""} class="dt-research-chip dt-research-score"><%= @relevance_label %></span>
        </div>
      </td>
      <td class="dt-td dt-td-row-actions">
        <.delete_button row_id={@row_id_str} confirm_delete={@confirm_delete} myself={@myself} />
      </td>
    </tr>
    """
  end

  def research_fact_view(assigns) do
    assigns = assign_new(assigns, :full?, fn -> false end)

    ~H"""
    <div class={["dt-research-fact", @full? && "dt-research-fact-full"]}>
      <%= for block <- @blocks do %>
        <%= case block.kind do %>
          <% :paragraph -> %>
            <p class="dt-research-paragraph">
              <span :if={block.label} class="dt-research-block-label"><%= block.label %></span>
              <%= block.text %>
            </p>
          <% :section -> %>
            <div class="dt-research-section">
              <div class="dt-research-section-title"><%= block.title %></div>
              <p :if={block.text != ""} class="dt-research-paragraph"><%= block.text %></p>
            </div>
          <% :bullets -> %>
            <ul class="dt-research-fact-list">
              <li :for={item <- block.items}>
                <span :if={item.title != ""} class="dt-research-bullet-title"><%= item.title %></span>
                <span><%= item.text %></span>
              </li>
            </ul>
        <% end %>
      <% end %>
    </div>
    """
  end

  def research_edit_form(assigns) do
    assigns = assign_new(assigns, :multiline?, fn -> false end)

    ~H"""
    <form phx-submit="save_edit" phx-target={@myself}>
      <input type="hidden" name="row_id" value={@row_id} />
      <input type="hidden" name="field" value={@field} />
      <%= if @multiline? do %>
        <textarea
          name="value"
          class="dt-cell-input dt-research-input"
          phx-hook="AutoFocus"
          id={"edit-#{@row_id}-#{@field}"}
          phx-keydown="cancel_edit"
          phx-target={@myself}
          phx-key="Escape"
          phx-blur="save_edit"
          phx-target={@myself}
          phx-value-row_id={@row_id}
          phx-value-field={@field}
        ><%= @value %></textarea>
      <% else %>
        <input
          type="text"
          name="value"
          value={@value}
          class="dt-cell-input"
          phx-hook="AutoFocus"
          id={"edit-#{@row_id}-#{@field}"}
          phx-blur="save_edit"
          phx-target={@myself}
          phx-value-row_id={@row_id}
          phx-value-field={@field}
          phx-keydown="cancel_edit"
          phx-target={@myself}
          phx-key="Escape"
        />
      <% end %>
    </form>
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
          <span class="dt-cell-text" title={cell_title(@value)}><%= @value %></span>
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

  defp cell_title(value) when is_binary(value), do: value
  defp cell_title(_value), do: nil

  defp research_fact_blocks(value) do
    value
    |> research_fact_text()
    |> parse_research_fact()
  end

  defp research_fact_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[[:space:]]+/, " ")
  end

  defp research_fact_text(value), do: to_string(value || "")

  defp parse_research_fact(""), do: [%{kind: :paragraph, label: nil, text: ""}]

  defp parse_research_fact(text) do
    {label, body} = extract_research_label(text)
    {intro, items} = extract_research_items(body)

    intro
    |> research_intro_blocks(label)
    |> then(fn blocks ->
      if items == [] do
        blocks
      else
        blocks ++ [%{kind: :bullets, items: items}]
      end
    end)
  end

  defp extract_research_label(text) do
    case Regex.run(~r/^(Summary|Finding|Note|Context):\s*(.+)$/i, text) do
      [_, label, body] -> {String.capitalize(String.downcase(label)), String.trim(body)}
      _ -> {nil, text}
    end
  end

  defp extract_research_items(text) do
    dash_parts =
      Regex.split(~r/\s+(?:-|\x{2013}|\x{2014})\s+(?=[A-Z][A-Za-z0-9&\/, ]{1,64}:)/u, text)

    cond do
      match?([_, _ | _], dash_parts) ->
        [intro | item_parts] = dash_parts
        {intro, Enum.map(item_parts, &research_item_from_titled_text/1)}

      Regex.match?(~r/\s\d+\)\s+/, text) ->
        [intro | item_parts] = Regex.split(~r/\s+(?=\d+\)\s+)/, text)

        items =
          item_parts
          |> Enum.map(&String.replace(&1, ~r/^\d+\)\s*/, ""))
          |> Enum.map(&%{title: "", text: String.trim(&1)})

        {intro, items}

      true ->
        {text, []}
    end
  end

  defp research_intro_blocks(text, label) do
    text = String.trim(text)

    if text == "" do
      []
    else
      sentences = Regex.split(~r/(?<=[.!?])\s+/, text, trim: true)
      {paragraph_sentences, section_sentence} = split_section_sentence(sentences)
      paragraph = Enum.join(paragraph_sentences, " ")

      []
      |> maybe_append_paragraph(label, paragraph)
      |> maybe_append_section(section_sentence)
    end
  end

  defp split_section_sentence(sentences) do
    case List.pop_at(sentences, -1) do
      {last, rest} when is_binary(last) ->
        if String.ends_with?(last, ":") do
          {rest, last}
        else
          {sentences, nil}
        end

      _ ->
        {sentences, nil}
    end
  end

  defp maybe_append_paragraph(blocks, _label, ""), do: blocks

  defp maybe_append_paragraph(blocks, label, text) do
    blocks ++ [%{kind: :paragraph, label: label, text: text}]
  end

  defp maybe_append_section(blocks, nil), do: blocks

  defp maybe_append_section(blocks, text) do
    blocks ++ [%{kind: :section, title: trim_trailing_colon(text), text: ""}]
  end

  defp research_item_from_titled_text(text) do
    case String.split(text, ":", parts: 2) do
      [title, body] ->
        %{title: String.trim(title), text: String.trim(body)}

      [body] ->
        %{title: "", text: String.trim(body)}
    end
  end

  defp trim_trailing_colon(text) do
    text
    |> String.trim()
    |> String.trim_trailing(":")
  end

  defp external_href(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, ["https://", "http://"]) do
      trimmed
    end
  end

  defp external_href(_value), do: nil

  defp research_source_label(title, source) do
    if is_binary(title) and String.trim(title) != "" do
      String.trim(title)
    else
      research_source_domain(source)
    end
  end

  defp research_source_domain(source) when is_binary(source) do
    trimmed = String.trim(source)

    cond do
      trimmed == "" ->
        "Source unavailable"

      trimmed == "user" ->
        "Manual note"

      host = URI.parse(trimmed).host ->
        String.replace_prefix(host, "www.", "")

      true ->
        trimmed
    end
  end

  defp research_source_domain(_source), do: "Source unavailable"

  defp research_relevance_label(value) when is_float(value) do
    "#{round(value * 100)}% match"
  end

  defp research_relevance_label(value) when is_integer(value) do
    "#{value}% match"
  end

  defp research_relevance_label(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {score, ""} when score <= 1.0 -> research_relevance_label(score)
      {_score, ""} -> trimmed <> "% match"
      _ -> trimmed
    end
  end

  defp research_relevance_label(_value), do: ""

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false

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
