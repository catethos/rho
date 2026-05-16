defmodule RhoWeb.AppLiveFlowSessionTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.FlowRunner
  alias RhoFrameworks.Flows.CreateFramework
  alias RhoWeb.AppLive.FlowSession
  alias RhoWeb.Projections.DataTableProjection
  alias RhoWeb.Session.Shell
  alias RhoWeb.WorkbenchDisplay

  defp build_socket do
    sid = "flow_session_test_#{System.unique_integer([:positive])}"
    agent_id = Rho.Agent.Primary.agent_id(sid)

    assigns = %{
      __changed__: %{},
      flash: %{},
      session_id: sid,
      active_agent_id: agent_id,
      agent_messages: %{agent_id => []},
      next_id: 1,
      active_page: :chat,
      active_flow: nil,
      active_workspace_id: nil,
      shell: Shell.init([], [:data_table]),
      workspaces: %{},
      ws_states: %{data_table: DataTableProjection.init()},
      workbench_home_open?: true,
      workbench_display: WorkbenchDisplay.from_data_state(DataTableProjection.init(), :home),
      current_organization: %{id: Ecto.UUID.generate(), slug: "acme"},
      current_user: %{id: Ecto.UUID.generate()}
    }

    {sid, struct!(Phoenix.LiveView.Socket, assigns: assigns)}
  end

  test "start inserts the first create-framework flow card into chat" do
    {sid, socket} = build_socket()

    socket = FlowSession.start(socket, "create-framework", %{})
    agent_id = socket.assigns.active_agent_id
    [card] = socket.assigns.agent_messages[agent_id]

    assert socket.assigns.active_flow.id == "create-framework"
    assert socket.assigns.active_flow.runner.node_id == :choose_starting_point
    assert card.type == :flow_card
    assert card.flow.node_id == :choose_starting_point
    assert card.flow_status == :active

    DataTable.stop(sid)
  end

  test "button action advances the flow through FlowRunner" do
    {sid, socket} = build_socket()

    socket =
      socket
      |> FlowSession.start("create-framework", %{})
      |> FlowSession.handle_action(%{
        "action-id" => "scratch",
        "node-id" => "choose_starting_point"
      })

    agent_id = socket.assigns.active_agent_id
    messages = socket.assigns.agent_messages[agent_id]

    assert socket.assigns.active_flow.runner.intake[:starting_point] == "scratch"
    assert socket.assigns.active_flow.runner.node_id == :intake_scratch
    assert List.last(messages).flow.node_id == :intake_scratch
    assert Enum.any?(messages, &(&1[:flow_status] == :past))

    DataTable.stop(sid)
  end

  test "typed replies use the same current-step parser" do
    {sid, socket} = build_socket()

    socket =
      socket
      |> FlowSession.start("create-framework", %{})
      |> FlowSession.handle_reply("use a similar role")

    assert socket.assigns.active_flow.runner.intake[:starting_point] == "from_template"
    assert socket.assigns.active_flow.runner.node_id == :intake_template

    DataTable.stop(sid)
  end

  test "form submission captures field values from the current flow card" do
    {sid, socket} = build_socket()

    socket =
      socket
      |> FlowSession.start("create-framework", %{})
      |> FlowSession.handle_action(%{
        "action-id" => "from_template",
        "node-id" => "choose_starting_point"
      })
      |> FlowSession.handle_form(%{
        "node-id" => "intake_template",
        "name" => "Risk Analyst Framework",
        "description" => "Skills for risk analyst roles"
      })

    assert socket.assigns.active_flow.runner.intake[:name] == "Risk Analyst Framework"

    assert socket.assigns.active_flow.runner.intake[:description] ==
             "Skills for risk analyst roles"

    assert :intake_template in socket.assigns.active_flow.completed_steps

    messages = socket.assigns.agent_messages[socket.assigns.active_agent_id]

    submitted_card =
      Enum.find(messages, fn
        %{type: :flow_card, flow: %{node_id: :intake_template}} -> true
        _ -> false
      end)

    assert Enum.find(submitted_card.flow.fields, &(&1.name == :name)).value ==
             "Risk Analyst Framework"

    assert Enum.find(submitted_card.flow.fields, &(&1.name == :description)).value ==
             "Skills for risk analyst roles"

    assert Enum.any?(messages, fn
             %{role: :user, content: content} ->
               content =~ "Name: Risk Analyst Framework" and
                 content =~ "Description: Skills for risk analyst roles"

             _ ->
               false
           end)

    DataTable.stop(sid)
  end

  test "prefilled name and description skip the path-specific intake detour" do
    {sid, socket} = build_socket()

    socket =
      socket
      |> FlowSession.start("create-framework", %{
        name: "Risk Analyst Skill Framework",
        description: "Skill framework for risk analyst.",
        target_roles: "risk analyst"
      })
      |> FlowSession.handle_form(%{
        "node-id" => "choose_starting_point",
        "starting_point" => "scratch"
      })

    assert socket.assigns.active_flow.runner.node_id == :taxonomy_preferences
    assert :intake_scratch in socket.assigns.active_flow.completed_steps

    messages = socket.assigns.agent_messages[socket.assigns.active_agent_id]

    refute Enum.any?(messages, fn
             %{type: :flow_card, flow: %{node_id: :intake_scratch}} -> true
             _ -> false
           end)

    assert Enum.any?(messages, fn
             %{role: :user, content: "How would you like to start?: Start from scratch"} ->
               true

             _ ->
               false
           end)

    assert List.last(messages).flow.node_id == :taxonomy_preferences

    DataTable.stop(sid)
  end

  test "selection toggle updates selected ids and refreshes the active card" do
    {sid, socket} = build_socket()

    socket =
      socket
      |> FlowSession.start("create-framework", %{})
      |> FlowSession.handle_action(%{
        "action-id" => "from_template",
        "node-id" => "choose_starting_point"
      })

    flow =
      socket.assigns.active_flow
      |> Map.put(:runner, %{socket.assigns.active_flow.runner | node_id: :similar_roles})
      |> Map.put(:select_items, [
        %{id: "role-1", name: "Risk Analyst", role_family: "Risk", skill_count: 12}
      ])

    socket = %{socket | assigns: Map.put(socket.assigns, :active_flow, flow)}

    # Rebuild a focused socket at the select step without running DB-backed lookup.
    socket =
      socket
      |> FlowSession.handle_select_toggle(%{
        "node-id" => "similar_roles",
        "item-id" => "role-1"
      })

    assert socket.assigns.active_flow.selected_ids == ["role-1"]

    card = List.last(socket.assigns.agent_messages[socket.assigns.active_agent_id])
    assert card.flow.artifact.selected_count == 1
    assert hd(card.flow.actions).label == "Continue with 1 selected"

    DataTable.stop(sid)
  end

  test "focus table switches the workbench from home to the reviewed table" do
    {sid, socket} = build_socket()
    table_name = "library:Risk Analyst"
    {:ok, _pid} = DataTable.ensure_started(sid)
    :ok = DataTable.ensure_table(sid, table_name, RhoFrameworks.DataTableSchemas.library_schema())

    socket = FlowSession.start(socket, "create-framework", %{})

    runner =
      socket.assigns.active_flow.runner
      |> FlowRunner.put_summary(:pick_template, %{table_name: table_name})
      |> Map.put(:node_id, :review_clone)

    flow = %{socket.assigns.active_flow | runner: runner}
    socket = %{socket | assigns: Map.put(socket.assigns, :active_flow, flow)}

    socket =
      FlowSession.handle_action(socket, %{
        "action-id" => "focus_table",
        "node-id" => "review_clone"
      })

    data_state = socket.assigns.ws_states.data_table

    assert data_state.active_table == table_name
    assert data_state.active_snapshot.name == table_name
    refute socket.assigns.workbench_home_open?
    assert socket.assigns.workbench_display.mode == {:table, table_name}

    DataTable.stop(sid)
  end

  test "research long step writes pinned Exa rows that generation can read" do
    {sid, socket} = build_socket()

    Application.put_env(:rho_frameworks, :exa_client, __MODULE__.FakeExaClient)
    on_exit(fn -> Application.delete_env(:rho_frameworks, :exa_client) end)

    socket =
      FlowSession.start(socket, "create-framework", %{
        name: "Risk Analyst",
        description: "Skills for risk analyst roles",
        starting_point: "scratch"
      })

    runner =
      socket.assigns.active_flow.runner
      |> Map.put(:node_id, :research)

    flow = %{
      socket.assigns.active_flow
      | runner: runner,
        step_status: :idle,
        status: :awaiting_user
    }

    socket = %{socket | assigns: Map.put(socket.assigns, :active_flow, flow)}

    socket =
      FlowSession.handle_action(socket, %{
        "action-id" => "run",
        "node-id" => "research"
      })

    assert socket.assigns.active_flow.step_status == :running

    assert_receive {:flow_long_step_completed, :research,
                    %{table_name: "research_notes", inserted: 1, seen: 3} = summary},
                   1_000

    socket = FlowSession.complete_long_step(socket, :research, summary)

    assert socket.assigns.active_flow.runner.summaries[:research].table_name == "research_notes"

    [row] = DataTable.get_rows(sid, table: "research_notes")
    assert Rho.MapAccess.get(row, :pinned) == true
    assert Rho.MapAccess.get(row, :fact) =~ "risk analysts evaluate control effectiveness"

    input =
      CreateFramework.build_input(
        :generate_taxonomy,
        socket.assigns.active_flow.runner,
        socket.assigns.active_flow.scope
      )

    assert input.research =~ "risk analysts evaluate control effectiveness"

    DataTable.stop(sid)
  end

  defmodule FakeExaClient do
    def search(_query, _opts) do
      {:ok,
       [
         %{
           url: "https://example.com/risk",
           title: "Risk analyst competencies",
           summary:
             "Modern risk analysts evaluate control effectiveness and communicate exposure."
         }
       ]}
    end
  end
end
