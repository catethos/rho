defmodule Rho.Agent.Bootstrap do
  @moduledoc """
  Prepares the initial state seed for `Rho.Agent.Worker`.

  The worker remains the GenServer owner. This module owns the deterministic
  bootstrap decisions around RunSpec construction, tape selection, optional
  sandbox startup, and registry metadata derivation.
  """

  require Logger

  defstruct [
    :agent_id,
    :session_id,
    :role,
    :workspace,
    :real_workspace,
    :sandbox,
    :tape_module,
    :tape_ref,
    :agent_name,
    :run_spec,
    :depth,
    :description,
    user_id: nil,
    organization_id: nil,
    conversation_id: nil,
    thread_id: nil,
    capabilities: [],
    skills: []
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          session_id: String.t(),
          role: atom(),
          workspace: String.t(),
          real_workspace: String.t(),
          sandbox: Rho.Sandbox.t() | nil,
          tape_module: module(),
          tape_ref: term(),
          agent_name: atom(),
          run_spec: Rho.RunSpec.t(),
          depth: non_neg_integer(),
          description: String.t() | nil,
          user_id: String.t() | nil,
          organization_id: String.t() | nil,
          conversation_id: String.t() | nil,
          thread_id: String.t() | nil,
          capabilities: [atom()],
          skills: [term()]
        }

  @doc """
  Builds the normalized bootstrap seed from worker start options.
  """
  @spec prepare(keyword()) :: t()
  def prepare(opts) when is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    agent_name = Keyword.get(opts, :agent_name, :default)
    role = Keyword.get(opts, :role, :primary)
    explicit_capabilities = Keyword.get(opts, :capabilities, [])
    depth = Rho.Agent.Primary.depth_of(agent_id)

    run_spec = opts[:run_spec] || build_default_run_spec(opts, agent_name)
    tape_module = run_spec.tape_module || Rho.Tape.Projection.JSONL

    {tape_ref, effective_workspace, sandbox} =
      prepare_tape_and_workspace(
        opts,
        session_id,
        workspace,
        tape_module,
        run_spec.sandbox_enabled
      )

    capabilities =
      run_spec.plugins
      |> Rho.Config.capabilities_from_plugins()
      |> Kernel.++(explicit_capabilities)
      |> Enum.uniq()

    run_spec =
      finalize_run_spec(run_spec, opts,
        agent_id: agent_id,
        session_id: session_id,
        workspace: effective_workspace,
        depth: depth,
        tape_ref: tape_ref,
        tape_module: tape_module,
        agent_name: agent_name
      )

    %__MODULE__{
      agent_id: agent_id,
      session_id: session_id,
      role: role,
      workspace: effective_workspace,
      real_workspace: workspace,
      sandbox: sandbox,
      tape_module: tape_module,
      tape_ref: tape_ref,
      agent_name: agent_name,
      run_spec: run_spec,
      depth: depth,
      capabilities: capabilities,
      description: Keyword.get(opts, :description) || run_spec.description,
      skills: Keyword.get(opts, :skills) || run_spec.skills || [],
      user_id: Keyword.get(opts, :user_id),
      organization_id: Keyword.get(opts, :organization_id),
      conversation_id: run_spec.conversation_id,
      thread_id: run_spec.thread_id
    }
  end

  @doc """
  Registry metadata for a prepared worker seed.
  """
  @spec registry_entry(t()) :: map()
  def registry_entry(%__MODULE__{} = seed) do
    %{
      session_id: seed.session_id,
      role: seed.role,
      agent_name: seed.agent_name,
      capabilities: seed.capabilities,
      pid: self(),
      status: :idle,
      depth: seed.depth,
      description: seed.description,
      skills: seed.skills,
      tape_ref: seed.tape_ref
    }
  end

  @doc """
  Agent-started event payload for a prepared worker seed.
  """
  @spec started_event_data(t()) :: map()
  def started_event_data(%__MODULE__{} = seed) do
    %{
      role: seed.role,
      agent_name: seed.agent_name,
      capabilities: seed.capabilities,
      depth: seed.depth,
      model: seed.run_spec.model
    }
  end

  # Build a default RunSpec for callers that didn't pass `:run_spec`.
  # Reads `.rho.exs` config for the role and folds in legacy spawn-time
  # opts (`:tools`, `:system_prompt`, `:model`, `:max_steps`).
  @doc false
  @spec build_default_run_spec(keyword(), atom()) :: Rho.RunSpec.t()
  def build_default_run_spec(opts, agent_name) do
    config = Rho.Config.agent_config(agent_name)

    Rho.RunSpec.build(
      model: opts[:model] || config.model,
      system_prompt: opts[:system_prompt] || config.system_prompt,
      max_steps: opts[:max_steps] || config.max_steps,
      max_tokens: config.max_tokens,
      plugins: config.plugins,
      transformers: [],
      turn_strategy: config.turn_strategy,
      prompt_format: config[:prompt_format] || :markdown,
      provider: config.provider,
      description: config.description,
      skills: config.skills || [],
      avatar: config.avatar,
      tools: opts[:tools],
      agent_name: agent_name,
      conversation_id: opts[:conversation_id],
      thread_id: opts[:thread_id],
      sandbox_enabled: Rho.Config.sandbox_enabled?()
    )
  end

  defp prepare_tape_and_workspace(opts, session_id, workspace, tape_module, sandbox_enabled) do
    if opts[:tape_ref] do
      {opts[:tape_ref], workspace, nil}
    else
      tape_ref = tape_module.memory_ref(session_id, workspace)
      tape_module.bootstrap(tape_ref)
      {effective_workspace, sandbox} = maybe_start_sandbox(session_id, workspace, sandbox_enabled)
      {tape_ref, effective_workspace, sandbox}
    end
  end

  defp finalize_run_spec(run_spec, opts, fields) do
    %{
      run_spec
      | agent_id: fields[:agent_id],
        session_id: fields[:session_id],
        workspace: fields[:workspace],
        depth: fields[:depth],
        tape_name: fields[:tape_ref],
        tape_module: fields[:tape_module],
        agent_name: fields[:agent_name],
        user_id: Keyword.get(opts, :user_id) || run_spec.user_id,
        organization_id: Keyword.get(opts, :organization_id) || run_spec.organization_id,
        conversation_id: Keyword.get(opts, :conversation_id) || run_spec.conversation_id,
        thread_id: Keyword.get(opts, :thread_id) || run_spec.thread_id
    }
  end

  defp maybe_start_sandbox(session_id, workspace, sandbox_enabled) do
    if sandbox_enabled do
      case Rho.Sandbox.start(session_id, workspace) do
        {:ok, sandbox} ->
          {sandbox.mount_path, sandbox}

        {:error, reason} ->
          Logger.error("[Sandbox] Failed to start: #{reason}. Falling back to direct workspace.")
          {workspace, nil}
      end
    else
      {workspace, nil}
    end
  end
end
