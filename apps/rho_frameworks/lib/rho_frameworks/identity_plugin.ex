defmodule RhoFrameworks.IdentityPlugin do
  @moduledoc """
  Plugin that injects user and organization context into the agent's system prompt.

  Reads `user_id` and `organization_id` from `Rho.Context`, looks up the
  records from the database, and returns a prompt section with identity info
  plus any freeform context the user or org has configured.

  Safe to register globally — returns an empty list when IDs are nil.
  """

  @behaviour Rho.Plugin

  import Ecto.Query

  alias RhoFrameworks.Repo
  alias RhoFrameworks.Accounts.{User, Organization, Membership}

  @impl true
  def prompt_sections(_opts, %{user_id: nil}), do: []
  def prompt_sections(_opts, %{organization_id: nil}), do: []

  def prompt_sections(_opts, %{user_id: user_id, organization_id: org_id}) do
    case load_identity(user_id, org_id) do
      nil -> []
      identity -> build_sections(identity)
    end
  end

  def prompt_sections(_opts, _ctx), do: []

  defp load_identity(user_id, org_id) do
    from(u in User,
      where: u.id == ^user_id,
      left_join: m in Membership,
      on: m.user_id == u.id and m.organization_id == ^org_id,
      left_join: o in Organization,
      on: o.id == ^org_id,
      select: %{user: u, org: o, role: m.role},
      limit: 1
    )
    |> Repo.one()
  end

  defp build_sections(%{user: user, org: org, role: role}) do
    lines =
      []
      |> add_user_lines(user)
      |> add_org_lines(org)
      |> add_role_line(role)

    if lines == [] do
      []
    else
      body = Enum.join(lines, "\n")
      [%Rho.PromptSection{heading: "Identity", body: body, priority: 10}]
    end
  end

  defp add_user_lines(lines, nil), do: lines

  defp add_user_lines(lines, user) do
    name = user.display_name || user.email
    lines = lines ++ ["User: #{name} (#{user.email})"]

    if user.context && user.context != "" do
      lines ++ ["User context: #{user.context}"]
    else
      lines
    end
  end

  defp add_org_lines(lines, nil), do: lines

  defp add_org_lines(lines, org) do
    label = if org.personal, do: "Personal workspace", else: "Organization: #{org.name}"
    lines = lines ++ [label]

    if org.context && org.context != "" do
      lines ++ ["Organization context: #{org.context}"]
    else
      lines
    end
  end

  defp add_role_line(lines, nil), do: lines
  defp add_role_line(lines, role), do: lines ++ ["Role: #{role}"]
end
