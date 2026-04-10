defmodule RhoFrameworks.Accounts do
  @moduledoc "User account management context."

  import Ecto.Query
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Accounts.{User, UserToken, Organization, Membership}

  ## Registration

  def register_user(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:organization, fn _repo, %{user: user} ->
      create_personal_organization(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
      {:error, :organization, changeset, _} -> {:error, changeset}
    end
  end

  ## Authentication

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  ## Session tokens

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    UserToken.verify_session_token_query(token)
    |> Repo.one()
  end

  def delete_user_session_token(token) do
    from(t in UserToken, where: t.token == ^token and t.context == "session")
    |> Repo.delete_all()

    :ok
  end

  ## Changesets

  def change_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, validate: false)
  end

  def change_user_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  def update_user_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  ## Lookup

  def get_user!(id), do: Repo.get!(User, id)

  ## Organizations

  def create_organization(attrs, owner_user) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, Organization.changeset(%Organization{}, attrs))
    |> Ecto.Multi.insert(:membership, fn %{organization: org} ->
      Membership.changeset(%Membership{}, %{
        user_id: owner_user.id,
        organization_id: org.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: org}} -> {:ok, org}
      {:error, :organization, changeset, _} -> {:error, changeset}
      {:error, :membership, changeset, _} -> {:error, changeset}
    end
  end

  def create_personal_organization(user) do
    base =
      (user.display_name || user.email |> String.split("@") |> hd())
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    short_id = user.id |> String.slice(0, 8)
    slug = "personal-#{base}-#{short_id}"

    create_organization(%{name: "Personal", slug: slug, personal: true}, user)
  end

  def get_organization_by_slug(slug) do
    Repo.get_by(Organization, slug: slug)
  end

  def get_organization_by_slug!(slug) do
    Repo.get_by!(Organization, slug: slug)
  end

  def get_default_organization(user) do
    from(m in Membership,
      where: m.user_id == ^user.id,
      join: o in assoc(m, :organization),
      where: o.personal == true,
      select: o,
      limit: 1
    )
    |> Repo.one()
  end

  def list_user_organizations(user_id) do
    from(m in Membership,
      where: m.user_id == ^user_id,
      join: o in assoc(m, :organization),
      select: %{organization: o, role: m.role},
      order_by: [asc: o.name]
    )
    |> Repo.all()
  end

  def get_membership(user_id, organization_id) do
    Repo.get_by(Membership, user_id: user_id, organization_id: organization_id)
  end

  def get_membership!(user_id, organization_id) do
    Repo.get_by!(Membership, user_id: user_id, organization_id: organization_id)
  end

  def update_organization(%Organization{} = org, attrs) do
    org
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  def delete_organization(%Organization{personal: true}),
    do: {:error, :cannot_delete_personal_org}

  def delete_organization(%Organization{} = org) do
    Repo.delete(org)
  end

  def change_organization(%Organization{} = org, attrs \\ %{}) do
    Organization.changeset(org, attrs)
  end

  def count_members(organization_id) do
    from(m in Membership, where: m.organization_id == ^organization_id, select: count())
    |> Repo.one()
  end

  def list_user_organizations_with_counts(user_id) do
    counts_subquery =
      from(m in Membership,
        group_by: m.organization_id,
        select: %{organization_id: m.organization_id, count: count()}
      )

    from(m in Membership,
      where: m.user_id == ^user_id,
      join: o in assoc(m, :organization),
      left_join: c in subquery(counts_subquery),
      on: c.organization_id == o.id,
      select: %{organization: o, role: m.role, member_count: coalesce(c.count, 0)},
      order_by: [asc: o.name]
    )
    |> Repo.all()
  end

  def transfer_ownership(organization_id, new_owner_user_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:old_owner, fn _repo, _ ->
      case Repo.one(
             from(m in Membership,
               where: m.organization_id == ^organization_id and m.role == "owner"
             )
           ) do
        nil -> {:error, :no_current_owner}
        m -> {:ok, m}
      end
    end)
    |> Ecto.Multi.run(:new_owner, fn _repo, _ ->
      case Repo.get_by(Membership,
             user_id: new_owner_user_id,
             organization_id: organization_id
           ) do
        nil -> {:error, :not_a_member}
        m -> {:ok, m}
      end
    end)
    |> Ecto.Multi.update(:demote_old, fn %{old_owner: old} ->
      Membership.changeset(old, %{role: "admin"})
    end)
    |> Ecto.Multi.update(:promote_new, fn %{new_owner: new} ->
      Membership.changeset(new, %{role: "owner"})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  ## Member management

  def add_member(organization_id, user_email, role) do
    case Repo.get_by(User, email: user_email) do
      nil ->
        {:error, :user_not_found}

      user ->
        %Membership{}
        |> Membership.changeset(%{
          user_id: user.id,
          organization_id: organization_id,
          role: role
        })
        |> Repo.insert()
    end
  end

  def update_member_role(membership_id, new_role) do
    Repo.get!(Membership, membership_id)
    |> Membership.changeset(%{role: new_role})
    |> Repo.update()
  end

  def remove_member(membership_id) do
    membership = Repo.get!(Membership, membership_id)

    if membership.role == "owner" do
      {:error, :cannot_remove_owner}
    else
      Repo.delete(membership)
    end
  end

  def list_members(organization_id) do
    from(m in Membership,
      where: m.organization_id == ^organization_id,
      join: u in assoc(m, :user),
      select: %{
        id: m.id,
        user_id: u.id,
        email: u.email,
        display_name: u.display_name,
        role: m.role
      },
      order_by: [asc: m.role, asc: u.email]
    )
    |> Repo.all()
  end
end
