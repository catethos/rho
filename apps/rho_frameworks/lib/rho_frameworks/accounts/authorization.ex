defmodule RhoFrameworks.Accounts.Authorization do
  @moduledoc false
  @role_levels %{"owner" => 4, "admin" => 3, "member" => 2, "viewer" => 1}

  def role_at_least?(user_role, minimum_role) do
    Map.get(@role_levels, user_role, 0) >= Map.get(@role_levels, minimum_role, 0)
  end

  def can?(membership, action)
  def can?(%{role: role}, :view), do: role_at_least?(role, "viewer")
  def can?(%{role: role}, :create), do: role_at_least?(role, "member")
  def can?(%{role: role}, :edit), do: role_at_least?(role, "member")
  def can?(%{role: role}, :delete), do: role_at_least?(role, "member")
  def can?(%{role: role}, :manage_members), do: role_at_least?(role, "admin")
  def can?(%{role: role}, :manage_org), do: role_at_least?(role, "owner")
  def can?(nil, _action), do: false
end
