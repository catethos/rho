defmodule RhoWeb.UserRegistrationLive do
  use Phoenix.LiveView
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  alias RhoFrameworks.Accounts
  alias RhoFrameworks.Accounts.User
  alias RhoWeb.RateLimiter
  alias RhoWeb.RemoteIpHelper

  # 5 registrations per IP per hour. Generous enough for shared-NAT setups
  # (offices, dorms) but tight enough to stop scripted account spam.
  @register_window_ms :timer.hours(1)
  @register_max 5

  def mount(_params, _session, socket) do
    changeset = Accounts.change_registration(%User{})

    socket =
      socket
      |> assign(form: to_form(changeset, as: "user"), active_page: :auth)
      |> assign(:client_ip, peer_ip(socket))

    {:ok, socket}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case RateLimiter.hit(
           "register:ip:" <> socket.assigns.client_ip,
           @register_window_ms,
           @register_max
         ) do
      {:allow, _count} ->
        do_save(socket, user_params)

      {:deny, retry_after_ms} ->
        minutes = div(retry_after_ms, 60_000) + 1

        {:noreply,
         put_flash(
           socket,
           :error,
           "Too many registration attempts. Please try again in about #{minutes} minute(s)."
         )}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> User.registration_changeset(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end

  defp do_save(socket, user_params) do
    case Accounts.register_user(user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully.")
         |> push_navigate(to: ~p"/users/log_in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end

  defp peer_ip(socket), do: RemoteIpHelper.from_socket(socket)

  def render(assigns) do
    ~H"""
    <div class="auth-container">
      <div class="auth-card">
        <div class="auth-logo">rho</div>
        <h1 class="auth-title">Register</h1>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <div class="auth-field">
            <label for="user_email">Email</label>
            <input
              type="email"
              id="user_email"
              name="user[email]"
              value={@form[:email].value}
              required
            />
            <.field_errors field={@form[:email]} />
          </div>

          <div class="auth-field">
            <label for="user_display_name">Display name</label>
            <input
              type="text"
              id="user_display_name"
              name="user[display_name]"
              value={@form[:display_name].value}
            />
          </div>

          <div class="auth-field">
            <label for="user_password">Password</label>
            <input
              type="password"
              id="user_password"
              name="user[password]"
              value={@form[:password].value}
              required
            />
            <.field_errors field={@form[:password]} />
          </div>

          <button type="submit" class="auth-button">Create account</button>
        </.form>

        <p class="auth-link">
          Already have an account? <a href={~p"/users/log_in"}>Sign in</a>
        </p>
      </div>
    </div>
    """
  end

  defp field_errors(assigns) do
    ~H"""
    <div :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="auth-error">
      <%= msg %>
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
