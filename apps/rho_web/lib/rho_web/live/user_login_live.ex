defmodule RhoWeb.UserLoginLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")
    {:ok, assign(socket, form: form, active_page: :auth), temporary_assigns: [form: form]}
  end

  def render(assigns) do
    ~H"""
    <div class="auth-container">
      <div class="auth-card">
        <div class="auth-logo">rho</div>
        <h1 class="auth-title">Sign in</h1>

        <.form for={@form} id="login_form" action={~p"/users/log_in"} phx-update="ignore">
          <div class="auth-field">
            <label for="user_email">Email</label>
            <input type="email" id="user_email" name="user[email]" value={@form[:email].value} required />
          </div>

          <div class="auth-field">
            <label for="user_password">Password</label>
            <input type="password" id="user_password" name="user[password]" required />
          </div>

          <button type="submit" class="auth-button">Sign in</button>
        </.form>

        <p class="auth-link">
          Don't have an account? <a href={~p"/users/register"}>Register</a>
        </p>
      </div>
    </div>
    """
  end
end
