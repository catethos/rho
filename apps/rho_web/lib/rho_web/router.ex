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

  # Public auth routes (redirect away if already logged in)
  scope "/", RhoWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    live_session :redirect_if_authenticated,
      on_mount: [{RhoWeb.UserAuth, :redirect_if_authenticated}] do
      live("/users/register", UserRegistrationLive, :new)
      live("/users/log_in", UserLoginLive, :new)
    end
  end

  pipeline :rate_limit_login do
    plug(RhoWeb.Plugs.LoginRateLimit)
  end

  # Auth controller (POST login/logout — must be regular controller for cookies)
  scope "/", RhoWeb do
    pipe_through([:browser, :rate_limit_login])

    post("/users/log_in", UserSessionController, :create)
  end

  scope "/", RhoWeb do
    pipe_through(:browser)

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
      live("/chat", AppLive, :chat_new)
      live("/chat/:session_id", AppLive, :chat_show)
      live("/libraries", AppLive, :libraries)
      live("/libraries/:id", AppLive, :library_show)
      live("/roles", AppLive, :roles)
      live("/roles/:id", AppLive, :role_show)
      live("/settings", AppLive, :settings)
      live("/members", AppLive, :members)
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

  # Admin / operator dashboards.
  #
  # NOTE: currently only gated by `:require_authenticated_user` — any
  # logged-in user can view. For production, add an admin-role plug
  # (e.g. `plug :require_admin`) to this scope before shipping.
  scope "/admin", RhoWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :admin,
      layout: {RhoWeb.Layouts, :app},
      on_mount: [{RhoWeb.UserAuth, :ensure_authenticated}] do
      live("/llm", Admin.LLMAdmissionLive, :index)
    end
  end
end
