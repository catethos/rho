defmodule RhoWeb.FlowLiveTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Accounts.Organization

  setup do
    org_id = Ecto.UUID.generate()
    slug = "flow-test-#{System.unique_integer([:positive])}"
    Repo.insert!(%Organization{id: org_id, name: "Flow Test Org", slug: slug})

    org = %{id: org_id, slug: slug, name: "Flow Test Org"}
    user = %{id: Ecto.UUID.generate(), email: "flow@test.com"}

    %{org_id: org_id, org: org, user: user}
  end

  defp build_socket(assigns_override) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{}
        },
        assigns_override
      )

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  defp put_connected(socket) do
    %{socket | transport_pid: self()}
  end

  describe "mount/3" do
    test "mounts with valid flow_id (connected)", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)

      assert socket.assigns.flow_module == RhoFrameworks.Flows.CreateFramework
      assert length(socket.assigns.flow_steps) == 7
      assert socket.assigns.current_step == :intake
      assert socket.assigns.completed_steps == []
      assert socket.assigns.step_status == :idle
      assert is_binary(socket.assigns.session_id)
      assert socket.assigns.runtime.mode == :flow

      # Clean up
      DataTable.stop(socket.assigns.session_id)
    end

    test "mounts with valid flow_id (disconnected)", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)

      assert socket.assigns.flow_module == RhoFrameworks.Flows.CreateFramework
      assert socket.assigns.session_id == nil
      assert socket.assigns.runtime == nil
    end

    test "redirects on unknown flow_id", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "nonexistent"}, %{}, socket)

      assert socket.redirected
    end
  end

  describe "handle_event submit_form" do
    test "stores form data and advances step", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      params = %{
        "step_id" => "intake",
        "name" => "Test Framework",
        "description" => "A test description"
      }

      {:noreply, socket} = RhoWeb.FlowLive.handle_event("submit_form", params, socket)

      # Should have stored intake results and moved to :generate
      assert socket.assigns.step_results[:intake][:name] == "Test Framework"
      assert socket.assigns.step_results[:intake][:description] == "A test description"
      assert socket.assigns.current_step == :generate
      assert :intake in socket.assigns.completed_steps

      # Action step should auto-run (step_status becomes :running)
      assert socket.assigns.step_status == :running

      DataTable.stop(sid)
    end
  end

  describe "handle_event continue" do
    test "advances to next step", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      # Manually set to review step (as if generate completed)
      socket =
        Phoenix.Component.assign(socket, %{
          current_step: :review,
          completed_steps: [:intake, :generate],
          step_status: :idle,
          step_results: %{
            intake: %{name: "Test", description: "Test"},
            generate: %{table_name: "library:Test", library: %{id: "lib-1"}}
          }
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_event("continue", %{}, socket)

      assert socket.assigns.current_step == :confirm
      assert :review in socket.assigns.completed_steps

      DataTable.stop(sid)
    end
  end
end
