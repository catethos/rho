defmodule RhoWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import RhoWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {RhoWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(RhoWeb.Plugs.APIAuth)
  end

  scope "/api", RhoWeb do
    pipe_through(:api)

    forward("/", ObservatoryAPI)
  end

  # Public auth routes (redirect away if already logged in)
  scope "/", RhoWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    live_session :redirect_if_authenticated,
      on_mount: [{RhoWeb.UserAuth, :redirect_if_authenticated}] do
      live("/users/register", UserRegistrationLive, :new)
      live("/users/log_in", UserLoginLive, :new)
    end
  end

  # Auth controller (POST login/logout — must be regular controller for cookies)
  scope "/", RhoWeb do
    pipe_through(:browser)

    post("/users/log_in", UserSessionController, :create)
    delete("/users/log_out", UserSessionController, :delete)
  end

  pipeline :load_organization do
    plug(RhoWeb.Plugs.LoadOrganization)
  end

  # Org-scoped protected routes
  scope "/orgs/:org_slug", RhoWeb do
    pipe_through([:browser, :require_authenticated_user, :load_organization])

    live_session :org_authenticated,
      layout: {RhoWeb.Layouts, :app},
      on_mount: [
        {RhoWeb.UserAuth, :ensure_authenticated},
        {RhoWeb.UserAuth, :ensure_org_member}
      ] do
      live("/roles", RoleProfileListLive, :index)
      live("/roles/:id", RoleProfileShowLive, :show)
      live("/libraries", SkillLibraryLive, :index)
      live("/libraries/:id", SkillLibraryShowLive, :show)
      live("/chat/:session_id", SessionLive, :show)
      live("/chat", SessionLive, :new)
      live("/observatory/:session_id", ObservatoryLive, :show)
      live("/observatory", ObservatoryLive, :new)
      live("/settings", OrgSettingsLive, :index)
      live("/members", OrgMembersLive, :index)
    end
  end

  # Protected routes (no org context)
  scope "/", RhoWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :authenticated,
      layout: {RhoWeb.Layouts, :app},
      on_mount: [{RhoWeb.UserAuth, :ensure_authenticated}] do
      live("/", OrgPickerLive, :index)
    end
  end
end
