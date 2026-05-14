defmodule Rho.RunSpec.FromConfig do
  @moduledoc """
  Builds a `%Rho.RunSpec{}` from `.rho.exs` via `Rho.AgentConfig`.

  This is the **only** place that touches `.rho.exs` or application env
  for agent configuration. Everything downstream receives an explicit
  RunSpec struct.

  ## Usage

      spec = Rho.RunSpec.FromConfig.build(:coder)
      spec = Rho.RunSpec.FromConfig.build(:default, workspace: "/tmp/project")
  """

  alias Rho.AgentConfig

  @doc """
  Build a RunSpec for the given agent name.

  Reads `.rho.exs` via `AgentConfig.agent/1`, resolves plugin shorthand
  atoms via `Rho.Stdlib.resolve_plugin/1`, and returns a `%Rho.RunSpec{}`.

  ## Options

  Any option passed here overrides the value from `.rho.exs`:

    * `:workspace` — working directory
    * `:session_id` — session namespace
    * `:agent_id` — unique agent process id
    * `:conversation_id` — durable conversation id
    * `:thread_id` — durable thread id
    * `:user_id` — multi-tenant scoping
    * `:organization_id` — multi-tenant scoping
    * `:emit` — event callback
    * `:model` — override the model from config
    * `:system_prompt` — override system prompt
    * `:max_steps` — override max steps
    * `:sandbox_enabled` — override sandbox setting
  """
  @spec build(atom(), keyword()) :: Rho.RunSpec.t()
  def build(agent_name \\ :default, opts \\ []) do
    config = AgentConfig.agent(agent_name)

    Rho.RunSpec.build(
      model: opts[:model] || config.model,
      system_prompt: opts[:system_prompt] || config.system_prompt,
      max_steps: opts[:max_steps] || config.max_steps,
      max_tokens: config.max_tokens,
      plugins: config.plugins,
      transformers: [],
      turn_strategy: config.turn_strategy,
      prompt_format: config.prompt_format || :markdown,
      provider: config.provider,
      description: config.description,
      skills: config.skills || [],
      avatar: config.avatar,
      agent_name: agent_name,
      workspace: opts[:workspace],
      session_id: opts[:session_id],
      agent_id: opts[:agent_id],
      conversation_id: opts[:conversation_id],
      thread_id: opts[:thread_id],
      turn_id: opts[:turn_id],
      user_id: opts[:user_id],
      organization_id: opts[:organization_id],
      emit: opts[:emit],
      sandbox_enabled: opts[:sandbox_enabled] || AgentConfig.sandbox_enabled?()
    )
  end
end
