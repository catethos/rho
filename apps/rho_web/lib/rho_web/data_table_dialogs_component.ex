defmodule RhoWeb.DataTableDialogsComponent do
  @moduledoc false

  use Phoenix.Component

  attr(:action_dialog, :any, default: nil)
  attr(:myself, :any, required: true)
  attr(:role_groups, :list, default: [])

  def dialogs(assigns) do
    ~H"""
    <%= if @action_dialog do %>
      <div class="dt-dialog-backdrop" phx-click="close_dialog" phx-target={@myself}>
        <div class="dt-dialog" phx-click="noop" phx-target={@myself}>
          <%= case @action_dialog do %>
            <% {:save, name} -> %>
              <h3 class="dt-dialog-title">Save Library</h3>
              <form phx-submit="confirm_save" phx-target={@myself}>
                <label class="dt-dialog-label">Library Name</label>
                <input
                  type="text"
                  name="name"
                  value={name}
                  class="dt-dialog-input"
                  phx-hook="AutoFocus"
                  id="save-dialog-name"
                />
                <div class="dt-dialog-actions">
                  <button
                    type="button"
                    class="dt-dialog-btn dt-dialog-cancel"
                    phx-click="close_dialog"
                    phx-target={@myself}
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="dt-dialog-btn dt-dialog-confirm dt-save-btn"
                    phx-disable-with="Saving..."
                  >
                    Save
                  </button>
                </div>
              </form>
            <% {:save_role, name, role_family} -> %>
              <h3 class="dt-dialog-title">Save Role</h3>
              <form phx-submit="confirm_save" phx-target={@myself}>
                <label class="dt-dialog-label">Role Name</label>
                <input
                  type="text"
                  name="name"
                  value={name}
                  class="dt-dialog-input"
                  phx-hook="AutoFocus"
                  id="save-role-dialog-name"
                />
                <label class="dt-dialog-label">
                  Role Group <span class="dt-dialog-hint">(optional)</span>
                </label>
                <input
                  type="text"
                  name="role_family"
                  value={role_family || ""}
                  class="dt-dialog-input"
                  id="save-role-dialog-family"
                  list="save-role-group-options"
                  placeholder="e.g. Digital, Data and IT Operations"
                />
                <datalist id="save-role-group-options">
                  <option :for={group <- @role_groups} value={group}></option>
                </datalist>
                <div class="dt-dialog-actions">
                  <button
                    type="button"
                    class="dt-dialog-btn dt-dialog-cancel"
                    phx-click="close_dialog"
                    phx-target={@myself}
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="dt-dialog-btn dt-dialog-confirm dt-save-btn"
                    phx-disable-with="Saving..."
                  >
                    Save
                  </button>
                </div>
              </form>
            <% {:publish, name} -> %>
              <h3 class="dt-dialog-title">Publish Library</h3>
              <form phx-submit="confirm_publish" phx-target={@myself}>
                <label class="dt-dialog-label">Library Name</label>
                <input
                  type="text"
                  name="name"
                  value={name}
                  class="dt-dialog-input"
                  phx-hook="AutoFocus"
                  id="publish-dialog-name"
                />
                <label class="dt-dialog-label">
                  Version Tag <span class="dt-dialog-hint">(e.g. 2026.1 — auto-generated if blank)</span>
                </label>
                <input
                  type="text"
                  name="version_tag"
                  value=""
                  class="dt-dialog-input"
                  id="publish-dialog-version"
                  placeholder="auto"
                />
                <div class="dt-dialog-actions">
                  <button
                    type="button"
                    class="dt-dialog-btn dt-dialog-cancel"
                    phx-click="close_dialog"
                    phx-target={@myself}
                  >
                    Cancel
                  </button>
                  <button type="submit" class="dt-dialog-btn dt-dialog-confirm dt-publish-btn">
                    Publish
                  </button>
                </div>
              </form>
            <% {:suggest, default_n} -> %>
              <h3 class="dt-dialog-title">Suggest more skills</h3>
              <form phx-submit="confirm_suggest" phx-target={@myself}>
                <label class="dt-dialog-label">
                  How many? <span class="dt-dialog-hint">(1–10)</span>
                </label>
                <input
                  type="number"
                  name="n"
                  value={default_n}
                  min="1"
                  max="10"
                  class="dt-dialog-input"
                  phx-hook="AutoFocus"
                  id="suggest-dialog-n"
                />
                <div class="dt-dialog-actions">
                  <button
                    type="button"
                    class="dt-dialog-btn dt-dialog-cancel"
                    phx-click="close_dialog"
                    phx-target={@myself}
                  >
                    Cancel
                  </button>
                  <button type="submit" class="dt-dialog-btn dt-dialog-confirm dt-suggest-btn">
                    Suggest
                  </button>
                </div>
              </form>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end
end
