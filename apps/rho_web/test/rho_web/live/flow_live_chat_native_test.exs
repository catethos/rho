defmodule RhoWeb.FlowLiveChatNativeTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.{FlowRunner, Repo}
  alias RhoFrameworks.Flows.CreateFramework

  setup do
    org_id = Ecto.UUID.generate()
    slug = "flow-chat-test-#{System.unique_integer([:positive])}"
    Repo.insert!(%Organization{id: org_id, name: "Flow Chat Test Org", slug: slug})

    org = %{id: org_id, slug: slug, name: "Flow Chat Test Org"}
    user = %{id: Ecto.UUID.generate(), email: "flow-chat@test.com"}

    %{org: org, user: user}
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

  defp assign_role_transform(socket) do
    role_id = Ecto.UUID.generate()

    runner =
      FlowRunner.init(CreateFramework,
        start: :role_transform,
        intake: %{name: "Risk", description: "Risk framework"}
      )
      |> FlowRunner.put_summary(:similar_roles, %{
        matches: [%{id: role_id, name: "Risk Analyst"}],
        selected: [%{id: role_id, name: "Risk Analyst"}],
        skip_reason: nil
      })

    %{socket | assigns: Map.merge(socket.assigns, %{runner: runner, mode: :chat_native})}
  end

  defp assign_review_taxonomy(socket) do
    runner =
      FlowRunner.init(CreateFramework,
        start: :review_taxonomy,
        intake: %{
          name: "Risk",
          description: "Risk framework",
          taxonomy_size: "balanced",
          transferability: "mixed",
          specificity: "general"
        }
      )
      |> FlowRunner.put_summary(:generate_taxonomy, %{
        taxonomy_table_name: "taxonomy:Risk",
        table_name: "taxonomy:Risk"
      })

    %{socket | assigns: Map.merge(socket.assigns, %{runner: runner, mode: :chat_native})}
  end

  describe "chat-native flow controls" do
    test "mode param enables chat_native without changing the old default", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "chat_native"},
          %{},
          socket
        )

      assert socket.assigns.mode == :chat_native

      DataTable.stop(socket.assigns.session_id)
    end

    test "structured role_transform action advances through the clone branch", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "chat_native"},
          %{},
          socket
        )

      sid = socket.assigns.session_id
      socket = assign_role_transform(socket)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event("flow_chat_action", %{"action-id" => "clone"}, socket)

      assert socket.assigns.runner.intake[:role_transform] == "clone"
      assert socket.assigns.runner.node_id == :pick_template

      assert [%{kind: :flow_choice, meta: %{source: :structured_action}}] =
               socket.assigns.flow_chat_events

      DataTable.stop(sid)
    end

    test "natural-language role_transform reply advances through the inspiration branch", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "chat_native"},
          %{},
          socket
        )

      sid = socket.assigns.session_id
      socket = assign_role_transform(socket)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "flow_chat_reply",
          %{"message" => "use them as inspiration"},
          socket
        )

      assert socket.assigns.runner.intake[:role_transform] == "inspire"
      assert socket.assigns.runner.node_id == :taxonomy_preferences

      assert [%{kind: :flow_choice, meta: %{source: :natural_language}}] =
               socket.assigns.flow_chat_events

      DataTable.stop(sid)
    end

    test "artifact focus action marks the review table active and refreshes it", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "chat_native"},
          %{},
          socket
        )

      sid = socket.assigns.session_id

      :ok =
        DataTable.ensure_table(
          sid,
          "taxonomy:Risk",
          RhoFrameworks.DataTableSchemas.taxonomy_schema()
        )

      socket = assign_review_taxonomy(socket)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event("flow_chat_action", %{"action-id" => "focus_table"}, socket)

      assert DataTable.get_active_table(sid) == "taxonomy:Risk"
      assert socket.assigns.dt_schema.title == "Framework Taxonomy"

      assert [%{kind: :flow_choice, meta: %{action_id: "focus_table"}}] =
               socket.assigns.flow_chat_events

      DataTable.stop(sid)
    end

    test "artifact regenerate action routes back to the generating node", %{
      org: org,
      user: user
    } do
      parent = self()

      Application.put_env(:rho_web, :flow_long_step_spawn_fn, fn _fun ->
        send(parent, :long_step_spawned)
        {:ok, self()}
      end)

      on_exit(fn -> Application.delete_env(:rho_web, :flow_long_step_spawn_fn) end)

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "chat_native"},
          %{},
          socket
        )

      sid = socket.assigns.session_id

      socket =
        socket
        |> assign_review_taxonomy()
        |> Map.update!(:assigns, &Map.put(&1, :completed_steps, [:generate_taxonomy]))

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "flow_chat_reply",
          %{"message" => "regenerate taxonomy"},
          socket
        )

      assert_received :long_step_spawned
      assert socket.assigns.runner.node_id == :generate_taxonomy
      assert socket.assigns.step_status == :running
      refute :generate_taxonomy in socket.assigns.completed_steps

      assert [%{kind: :flow_choice, meta: %{action_id: "regenerate_taxonomy"}}] =
               socket.assigns.flow_chat_events

      DataTable.stop(sid)
    end
  end
end
