defmodule RhoWeb.FlowChat.StepAgent do
  @moduledoc """
  Launches the constrained per-step chat agent for flow action nodes.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoFrameworks.AgentJobs
  alias RhoFrameworks.Tools.WorkflowTools
  alias RhoWeb.FlowChat.StepPrompt

  @spec available?(map() | nil) :: boolean()
  def available?(nil), do: false

  def available?(step) do
    use_case = Map.get(step, :use_case)
    routing = Map.get(step, :routing)

    use_case && routing != :agent_loop && WorkflowTools.tool_for_use_case(use_case)
  end

  @spec disabled?(map(), atom()) :: boolean()
  def disabled?(%{type: :fan_out}, :running), do: true
  def disabled?(%{id: :generate}, :running), do: true
  def disabled?(%{id: :generate_taxonomy}, :running), do: true
  def disabled?(%{id: :generate_skills}, :running), do: true
  def disabled?(_step, _status), do: false

  @spec spawn(Phoenix.LiveView.Socket.t(), String.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def spawn(socket, message, opts) when is_binary(message) do
    step = Keyword.fetch!(opts, :step)
    table_name = Keyword.fetch!(opts, :table_name)
    runner = socket.assigns.runner
    use_case = step && Map.get(step, :use_case)
    use_case_tool = use_case && WorkflowTools.tool_for_use_case(use_case)
    scope = socket.assigns.scope

    cond do
      is_nil(use_case_tool) ->
        socket

      disabled?(step, socket.assigns.step_status) ->
        socket

      is_nil(scope) or is_nil(scope.session_id) ->
        socket

      true ->
        do_spawn(socket, message, step, runner, table_name, use_case_tool, scope)
    end
  end

  defp do_spawn(socket, message, step, runner, table_name, use_case_tool, scope) do
    config = Rho.AgentConfig.agent(:default)
    tools = [use_case_tool, WorkflowTools.clarify_tool()]

    spawn_args = [
      task: message,
      parent_agent_id: scope.session_id,
      tools: tools,
      model: config.model,
      system_prompt: system_prompt(step, runner, table_name, tools),
      max_steps: 5,
      turn_strategy: Rho.TurnStrategy.Direct,
      provider: config.provider || %{},
      agent_name: :step_chat,
      session_id: scope.session_id,
      organization_id: scope.organization_id
    ]

    case spawn_fn().(spawn_args) do
      {:ok, agent_id} when is_binary(agent_id) ->
        socket
        |> assign(:step_chat_agent_id, agent_id)
        |> assign(:step_chat_pending_question, nil)
        |> assign(:streaming_text, "")
        |> assign(:tool_events, [])

      _ ->
        socket
    end
  end

  defp system_prompt(step, runner, table_name, tools) do
    StepPrompt.build(runner.flow_mod, runner,
      step: step,
      table_name: table_name,
      tool_names: Enum.map(tools, & &1.tool.name)
    )
  end

  defp spawn_fn do
    Application.get_env(:rho_web, :step_chat_spawn_fn, &AgentJobs.start/1)
  end
end
