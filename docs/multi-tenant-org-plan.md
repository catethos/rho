# Multi-Tenant Organization Plan

## Goal

Add organization-based multi-tenancy to `rho_frameworks`. Users belong to organizations via memberships with role-based access. All data (frameworks, skills) is scoped to an organization instead of a user.

---

## Decisions Required

> **These must be resolved before implementation begins.**

### 1. Personal org semantics — single-user or team-capable?

**Option A (recommended): Personal orgs are single-user only.**
- Cannot invite members to a personal org.
- Team collaboration requires creating a separate team org.
- Cleaner UX, simpler mental model.

**Option B: Personal orgs behave like normal orgs.**
- Members can be invited to personal orgs.
- Simpler code (no special-casing), but blurs the boundary.

**Affects:** invite flow, ownership transfer, delete guards, org picker labels, "create org" UX.

### 2. Owner cardinality — single or multiple owners per org?

**Option A (recommended): Single owner per org.**
- Enforce with a partial unique index: `unique_index(:memberships, [:organization_id], where: "role = 'owner'")`.
- Ownership transfer is explicit (swap owner + demote old owner in a transaction).

**Option B: Multiple owners allowed.**
- Simpler to implement (no partial index needed).
- But makes "who is THE owner" ambiguous for billing, deletion, etc.

### 3. Slug mutability in v1

**Recommended: Slugs are immutable in v1.**
- Org `name` can be changed, but `slug` is set once at creation.
- Avoids broken bookmarks, redirect complexity, and slug-squatting issues.
- Can revisit in a later phase if users request it.

---

## Data Model

### New Tables

#### `organizations`

| Column | Type | Constraints |
|--------|------|-------------|
| id | binary_id (UUID) | PK, autogenerate |
| name | string | required, max 100 |
| slug | string | required, unique, max 60, **immutable in v1**, lowercase alphanumeric + hyphens |
| personal | boolean | default false — marks auto-created personal orgs |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

#### `memberships`

| Column | Type | Constraints |
|--------|------|-------------|
| id | binary_id (UUID) | PK, autogenerate |
| user_id | references(:users) | on_delete: delete_all |
| organization_id | references(:organizations) | on_delete: delete_all |
| role | string | required, one of: "owner", "admin", "member", "viewer" |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

Unique index on `[user_id, organization_id]`.

### Modified Tables

#### `frameworks` — add `organization_id`

| Column | Change |
|--------|--------|
| organization_id | ADD, references(:organizations), on_delete: delete_all |
| user_id | DROP (in a separate cleanup migration, after app cutover) |

New unique index on `[organization_id, name]` (replaces old `[user_id, name]`).

---

## Role Hierarchy

```
owner > admin > member > viewer
```

| Permission | owner | admin | member | viewer |
|------------|-------|-------|--------|--------|
| Delete organization | ✓ | | | |
| Transfer ownership | ✓ | | | |
| Manage billing/settings | ✓ | | | |
| Invite/remove members | ✓ | ✓ | | |
| Change member roles | ✓ | ✓ (not owner) | | |
| Create frameworks | ✓ | ✓ | ✓ | |
| Edit/delete frameworks | ✓ | ✓ | ✓ | |
| View frameworks | ✓ | ✓ | ✓ | ✓ |
| Search skills | ✓ | ✓ | ✓ | ✓ |

**v1 simplification:** Members can edit/delete all frameworks in their org. No per-framework ownership tracking (`created_by_id` deferred to a later phase).

---

## Implementation Phases

The rollout is split into three stages to be safe on SQLite: **additive → app cutover → cleanup**.

### Phase 1: Additive Schema & Data Migration

All additive — no columns dropped, no destructive changes.

#### Step 1.1 — Create Organization schema

File: `apps/rho_frameworks/lib/rho_frameworks/accounts/organization.ex`

```elixir
defmodule RhoFrameworks.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :personal, :boolean, default: false

    has_many :memberships, RhoFrameworks.Accounts.Membership
    has_many :users, through: [:memberships, :user]
    has_many :frameworks, RhoFrameworks.Frameworks.Framework

    timestamps(type: :utc_datetime)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :personal])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 100)
    |> validate_length(:slug, max: 60)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, message: "must be lowercase alphanumeric with hyphens, no leading/trailing hyphens")
    |> unique_constraint(:slug)
  end
end
```

#### Step 1.2 — Create Membership schema

File: `apps/rho_frameworks/lib/rho_frameworks/accounts/membership.ex`

```elixir
defmodule RhoFrameworks.Accounts.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin member viewer)

  schema "memberships" do
    field :role, :string, default: "member"

    belongs_to :user, RhoFrameworks.Accounts.User
    belongs_to :organization, RhoFrameworks.Accounts.Organization

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :organization_id, :role])
    |> validate_required([:user_id, :organization_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :organization_id])
  end

  def roles, do: @roles
end
```

#### Step 1.3 — Migration: create organizations

```elixir
defmodule RhoFrameworks.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :personal, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])
  end
end
```

#### Step 1.4 — Migration: create memberships

```elixir
defmodule RhoFrameworks.Repo.Migrations.CreateMemberships do
  use Ecto.Migration

  def change do
    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "member"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:user_id, :organization_id])
    create index(:memberships, [:organization_id])
  end
end
```

#### Step 1.5 — Migration: add organization_id to frameworks (nullable) + backfill

**Key changes from original plan:**
- **Fresh UUIDs** for orgs — do NOT reuse `user.id` as `org.id`.
- **Backfill in Elixir** using `Ecto.UUID.generate/0` — not raw SQL `hex(randomblob(16))`.
- **Slug from display name + short ID suffix** — not derived from email.
- **`organization_id` stays nullable** — NOT NULL enforced at app layer until cleanup migration.
- **`user_id` NOT dropped yet** — deferred to cleanup migration.

```elixir
defmodule RhoFrameworks.Repo.Migrations.AddOrganizationIdToFrameworks do
  use Ecto.Migration

  import Ecto.Query

  def up do
    # 1. Add nullable organization_id
    alter table(:frameworks) do
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all)
    end

    create index(:frameworks, [:organization_id])

    flush()

    # 2. Backfill in Elixir — create personal org + membership + update frameworks per user
    users = repo().all(from u in "users", select: %{id: u.id, email: u.email, display_name: u.display_name, inserted_at: u.inserted_at, updated_at: u.updated_at})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for user <- users do
      org_id = Ecto.UUID.generate()
      slug = generate_personal_slug(user)

      org_name = if user.display_name, do: "#{user.display_name}'s Org", else: "Personal"

      repo().insert_all("organizations", [
        %{id: org_id, name: org_name, slug: slug, personal: true, inserted_at: user.inserted_at || now, updated_at: user.updated_at || now}
      ])

      membership_id = Ecto.UUID.generate()
      repo().insert_all("memberships", [
        %{id: membership_id, role: "owner", user_id: user.id, organization_id: org_id, inserted_at: now, updated_at: now}
      ])

      repo().update_all(
        from(f in "frameworks", where: f.user_id == ^user.id),
        set: [organization_id: org_id]
      )
    end

    # 3. Add unique index on (organization_id, name) after backfill
    create unique_index(:frameworks, [:organization_id, :name])
  end

  def down do
    drop_if_exists index(:frameworks, [:organization_id, :name])
    drop_if_exists index(:frameworks, [:organization_id])

    alter table(:frameworks) do
      remove :organization_id
    end
  end

  defp generate_personal_slug(user) do
    base = (user.display_name || user.email |> String.split("@") |> hd())
           |> String.downcase()
           |> String.replace(~r/[^a-z0-9-]/, "-")
           |> String.replace(~r/-+/, "-")
           |> String.trim("-")
           |> String.slice(0, 40)

    short_id = user.id |> String.slice(0, 8)
    "personal-#{base}-#{short_id}"
  end
end
```

#### Step 1.6 — Update User schema

Add association to memberships/orgs in `User`:

```elixir
# In User schema block, add:
has_many :memberships, RhoFrameworks.Accounts.Membership
has_many :organizations, through: [:memberships, :organization]
```

#### Step 1.7 — Update Framework schema

Add `belongs_to :organization` alongside existing `belongs_to :user` (user kept until cleanup):

```elixir
# In Framework schema block, add:
belongs_to :organization, RhoFrameworks.Accounts.Organization
# Keep belongs_to :user for now — removed in cleanup migration
```

#### Step 1.8 — Test helper

Add a helper that creates user + personal org + membership in one call:

```elixir
def create_user_with_org(attrs \\ %{}) do
  {:ok, user} = Accounts.register_user(attrs)
  {:ok, org} = Accounts.create_personal_organization(user)
  membership = Accounts.get_membership!(user.id, org.id)
  %{user: user, organization: org, membership: membership}
end
```

---

### Phase 2: Context Layer — Organizations & Authorization

#### Step 2.1 — Add organization functions to Accounts context

File: `apps/rho_frameworks/lib/rho_frameworks/accounts.ex` — add:

```elixir
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
  base = (user.display_name || user.email |> String.split("@") |> hd())
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
```

#### Step 2.2 — Add member management functions

```elixir
def add_member(organization_id, user_email, role) do
  case Repo.get_by(User, email: user_email) do
    nil -> {:error, :user_not_found}
    user ->
      %Membership{}
      |> Membership.changeset(%{user_id: user.id, organization_id: organization_id, role: role})
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
    select: %{id: m.id, user_id: u.id, email: u.email, display_name: u.display_name, role: m.role},
    order_by: [asc: m.role, asc: u.email]
  )
  |> Repo.all()
end
```

#### Step 2.3 — Centralized authorization module

File: `apps/rho_frameworks/lib/rho_frameworks/accounts/authorization.ex`

**Important:** This module is the single source of truth for permission checks. Use it from plugs, `on_mount`, context functions, and (later) API endpoints. Do NOT duplicate authorization logic.

```elixir
defmodule RhoFrameworks.Accounts.Authorization do
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
```

---

### Phase 3: Update Frameworks Context

#### Step 3.1 — Replace user_id scoping with organization_id

Every function in `RhoFrameworks.Frameworks` that takes `user_id` as first arg becomes `organization_id`:

| Before | After |
|--------|-------|
| `list_frameworks(user_id)` | `list_frameworks(organization_id)` |
| `get_framework(user_id, name)` | `get_framework(organization_id, name)` |
| `get_framework!(user_id, id)` | `get_framework!(organization_id, id)` |
| `save_framework(user_id, ...)` | `save_framework(organization_id, ...)` |
| `delete_framework(user_id, ...)` | `delete_framework(organization_id, ...)` |
| `search_skills(user_id, ...)` | `search_skills(organization_id, ...)` |
| `compare_frameworks(user_id, ...)` | `compare_frameworks(organization_id, ...)` |
| `find_duplicates(user_id, ...)` | `find_duplicates(organization_id, ...)` |

All `where: f.user_id == ^user_id` → `where: f.organization_id == ^organization_id`.

The Framework changeset also changes: `user_id` field → `organization_id` field.

---

### Phase 4: Web Layer — Plugs, Hooks & Registration

> **Registration and login redirect are in this phase (not deferred)** because once the app expects every user to have an org, new registrations must create one immediately.

#### Step 4.1 — Org-loading plug

File: `apps/rho_web/lib/rho_web/plugs/load_organization.ex`

```elixir
defmodule RhoWeb.Plugs.LoadOrganization do
  import Plug.Conn
  import Phoenix.Controller
  alias RhoFrameworks.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user
    slug = conn.params["org_slug"] || conn.path_params["org_slug"]

    with org when not is_nil(org) <- Accounts.get_organization_by_slug(slug),
         membership when not is_nil(membership) <- Accounts.get_membership(user.id, org.id) do
      conn
      |> assign(:current_organization, org)
      |> assign(:current_membership, membership)
    else
      _ ->
        conn
        |> put_flash(:error, "Organization not found or access denied.")
        |> redirect(to: "/")
        |> halt()
    end
  end
end
```

#### Step 4.2 — Role-gating plug

File: `apps/rho_web/lib/rho_web/plugs/require_role.ex`

```elixir
defmodule RhoWeb.Plugs.RequireRole do
  import Plug.Conn
  import Phoenix.Controller
  alias RhoFrameworks.Accounts.Authorization

  def init(opts), do: Keyword.fetch!(opts, :minimum)

  def call(conn, minimum_role) do
    if Authorization.role_at_least?(conn.assigns.current_membership.role, minimum_role) do
      conn
    else
      conn
      |> put_flash(:error, "You don't have permission to do that.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
```

#### Step 4.3 — LiveView on_mount hook

Add to `RhoWeb.UserAuth`:

```elixir
def on_mount(:ensure_org_member, %{"org_slug" => slug}, session, socket) do
  socket = mount_current_user(socket, session)
  user = socket.assigns.current_user

  if user do
    org = Accounts.get_organization_by_slug(slug)
    membership = org && Accounts.get_membership(user.id, org.id)

    if membership do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_organization, org)
       |> Phoenix.Component.assign(:current_membership, membership)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  else
    {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")}
  end
end
```

#### Step 4.4 — Auto-create personal org on registration

In `Accounts.register_user/1`, wrap in a Multi:

```elixir
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
```

#### Step 4.5 — Post-login redirect

`UserAuth.log_in_user/3` should redirect to the user's default org:

```elixir
def log_in_user(conn, user, _params \\ %{}) do
  token = Accounts.generate_user_session_token(user)
  default_org = Accounts.get_default_organization(user)

  conn
  |> renew_session()
  |> put_session(:user_token, token)
  |> redirect(to: ~p"/orgs/#{default_org.slug}/spreadsheet")
end
```

---

### Phase 5: Routing

#### Step 5.1 — Restructure routes

```elixir
scope "/orgs/:org_slug", RhoWeb do
  pipe_through [:browser, :require_authenticated_user, :load_organization]

  # Framework routes
  live "/frameworks", FrameworkListLive
  live "/frameworks/:id", FrameworkShowLive
  live "/spreadsheet", SpreadsheetLive

  # Org settings (admin+)
  live "/settings", OrgSettingsLive
  live "/members", OrgMembersLive
end

# Top-level routes (no org context)
scope "/", RhoWeb do
  pipe_through [:browser, :require_authenticated_user]

  live "/", OrgPickerLive  # org selector / dashboard
end
```

#### Step 5.2 — Temporary redirects for old routes

Keep old routes alive temporarily to avoid breaking bookmarks/active sessions:

```elixir
# Redirect old /spreadsheet to user's default org
get "/spreadsheet", RedirectController, :spreadsheet_redirect
```

The redirect controller looks up the user's default org and redirects to `/orgs/:slug/spreadsheet`.

#### Step 5.3 — Add `:load_organization` to browser pipeline

```elixir
pipeline :load_organization do
  plug RhoWeb.Plugs.LoadOrganization
end
```

---

### Phase 6: UI

#### Step 6.1 — Org picker / dashboard

After login, if user has 1 org → redirect to it. If multiple → show picker.

For personal orgs, show "Personal" label. For team orgs, show org name + member count.

#### Step 6.2 — Create team organization flow

A "Create Organization" button on the org picker. Simple form: name + auto-generated slug.

#### Step 6.3 — Org settings page

- Rename org (name only — slug is immutable in v1)
- Owner-only: delete org (blocked for personal orgs)
- Display org ID for API usage

#### Step 6.4 — Member management page

- List members with roles
- Invite by email (admin+)
- Change roles (admin+ but not for owners)
- Remove members (admin+)
- Owner can transfer ownership

#### Step 6.5 — Org switcher in nav

Dropdown in the navbar showing current org with ability to switch. Similar to GitHub's org switcher.

#### Step 6.6 — Update existing LiveViews

All LiveViews that currently read `current_user.id` for framework queries switch to `current_organization.id`:

- `SpreadsheetLive` — scoped to org
- `FrameworkShowLive` — scoped to org
- `SessionLive` — scoped to org
- Any component that passes `user_id` to context functions

---

### Phase 7: Cleanup Migration

**Only run after the app cutover is deployed and stable.**

```elixir
defmodule RhoFrameworks.Repo.Migrations.CleanupFrameworksUserId do
  use Ecto.Migration

  def up do
    # Verify no NULLs remain
    # For SQLite, dropping a column requires a table rebuild.
    # Ecto will handle the rebuild via remove.
    alter table(:frameworks) do
      remove :user_id
    end

    # Drop old index if it exists
    drop_if_exists index(:frameworks, [:user_id, :name])
  end

  def down do
    alter table(:frameworks) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    # Best-effort reverse: assign frameworks to the org owner
    flush()
    execute """
    UPDATE frameworks
    SET user_id = (
      SELECT m.user_id FROM memberships m
      WHERE m.organization_id = frameworks.organization_id AND m.role = 'owner'
      LIMIT 1
    )
    """
  end
end
```

After this migration, also remove `belongs_to :user` from the Framework schema.

---

### Phase 8: Invitation System (deferred)

#### Step 8.1 — Invite tokens table

```elixir
create table(:org_invites, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
  add :email, :string  # optional — if set, only that email can accept
  add :role, :string, null: false, default: "member"
  add :token, :string, null: false
  add :expires_at, :utc_datetime, null: false
  add :accepted_at, :utc_datetime
  add :invited_by_id, references(:users, type: :binary_id), null: false

  timestamps(type: :utc_datetime)
end

create unique_index(:org_invites, [:token])
```

#### Step 8.2 — Invite flow

1. Admin creates invite → generates token URL: `/invites/:token`
2. Recipient visits URL → if logged in, joins org; if not, registers then joins
3. Token expires after 7 days
4. Optional: email-locked invites (only specific email can accept)

---

### Phase 9: API Scoping (deferred)

#### Step 9.1 — Per-org API tokens

Replace the single `RHO_API_TOKEN` env var with per-org tokens stored in DB:

```elixir
create table(:api_tokens, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
  add :name, :string, null: false
  add :token_hash, :string, null: false
  add :last_used_at, :utc_datetime
  add :created_by_id, references(:users, type: :binary_id), null: false

  timestamps(type: :utc_datetime)
end
```

Show the raw token only once on creation. Store only the hash. API requests include `Authorization: Bearer <token>` → look up by hash → load org.

---

## File Checklist

### New files
- [ ] `accounts/organization.ex` — Organization schema
- [ ] `accounts/membership.ex` — Membership schema
- [ ] `accounts/authorization.ex` — Centralized role checks
- [ ] Migration: create organizations
- [ ] Migration: create memberships
- [ ] Migration: add organization_id to frameworks + backfill
- [ ] Migration: cleanup — drop user_id (Phase 7)
- [ ] `plugs/load_organization.ex` — Org-loading plug
- [ ] `plugs/require_role.ex` — Role-gating plug
- [ ] `live/org_picker_live.ex` — Org dashboard/picker
- [ ] `live/org_settings_live.ex` — Org settings
- [ ] `live/org_members_live.ex` — Member management
- [ ] Test helper: `create_user_with_org/1`

### Modified files
- [ ] `accounts/user.ex` — add memberships/organizations associations
- [ ] `accounts.ex` — add org/membership functions, update `register_user/1`
- [ ] `frameworks/framework.ex` — add organization association (keep user until Phase 7)
- [ ] `frameworks.ex` — user_id → organization_id in all functions
- [ ] `router.ex` — org-scoped routes + old-route redirects
- [ ] `user_auth.ex` — org-aware on_mount, redirect logic
- [ ] `user_session_controller.ex` — post-login redirect to default org
- [ ] All LiveViews using `current_user.id` for data access
- [ ] `RhoFrameworks.Plugin` — if it passes user_id to context functions

### Later phases
- [ ] Migration: create org_invites
- [ ] Migration: create api_tokens
- [ ] Invite acceptance LiveView
- [ ] API auth plug rewrite
- [ ] Cleanup: remove `belongs_to :user` from Framework schema

---

## Risks & Mitigations

1. **SQLite DDL limitations**: `ALTER COLUMN` isn't supported. The rollout is split into additive → cutover → cleanup to avoid destructive DDL in the critical migration. NOT NULL on `organization_id` is enforced at the application layer until the cleanup migration.

2. **UUID generation**: All UUIDs are generated in Elixir via `Ecto.UUID.generate/0`. Raw SQL `hex(randomblob(16))` produces invalid Ecto UUIDs and is not used.

3. **Org IDs are fresh**: Each personal org gets a new UUID. We do NOT reuse `user.id` as `org.id` — this avoids a migration-era identity coupling where migrated orgs share IDs with users but newly registered ones don't.

4. **Slug generation**: Slugs use `personal-<slugified-name>-<short-user-id>` format. The short ID suffix guarantees uniqueness without retry loops. Full emails are never exposed in URLs.

5. **Personal org deletion**: Personal orgs are not deletable. Guard this in the context layer.

6. **Registration window safety**: Registration flow updates (personal org creation + login redirect) ship in the same deploy as the org cutover (Phase 4). This prevents a window where new users exist without orgs.

7. **Old URL breakage**: Temporary redirects from old routes (e.g., `/spreadsheet`) to the user's default org route are maintained until Phase 7 cleanup.

8. **Existing tests**: All tests that call `Frameworks.*` with `user_id` will break. A `create_user_with_org/1` test helper is added in Phase 1 to ease migration.
