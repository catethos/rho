defmodule Rho.RunSpec do
  @moduledoc """
  Carries all agent configuration explicitly through the stack.

  `Rho.Session.start` builds a RunSpec, Worker stores it, Runner reads it.
  No global registries for config, no `{mod, fun}` callbacks, no application env.

  ## Building

      # Full control — no .rho.exs needed:
      spec = Rho.RunSpec.build(model: "mock:test", plugins: [:bash], max_steps: 5)

      # From .rho.exs:
      spec = Rho.RunSpec.FromConfig.build(:coder)

  ## Fields

  Configuration fields carry the agent's identity and behaviour. They are
  set once at session start and remain constant for the session's lifetime.
  Per-turn overrides (e.g. a different model for one turn) are applied by
  the caller before passing the spec to Runner.
  """

  @enforce_keys [:model]
  defstruct [
    # LLM
    :model,
    :provider,
    :turn_strategy,
    :max_tokens,

    # Prompt
    :system_prompt,
    :prompt_format,

    # Loop
    :max_steps,
    :compact_threshold,

    # Plugins & transformers (config entries, not resolved instances)
    :plugins,
    :transformers,

    # Pre-resolved tools (nil = resolve from plugins at turn time)
    :tools,

    # Tape
    :tape_name,
    :tape_module,

    # Identity
    :agent_name,
    :agent_id,
    :session_id,
    :workspace,
    :depth,
    :subagent,
    :user_id,
    :organization_id,

    # Event delivery
    :emit,

    # Agent metadata (from .rho.exs)
    :description,
    :skills,
    :avatar,

    # Sandbox
    :sandbox_enabled,

    # Lite mode — skip tape, transformers, compaction, ToolExecutor.
    # Tools are executed directly. Designed for single-shot worker tasks.
    :lite
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          provider: term(),
          turn_strategy: module(),
          max_tokens: pos_integer() | nil,
          system_prompt: String.t(),
          prompt_format: :markdown | :xml,
          max_steps: pos_integer(),
          compact_threshold: pos_integer(),
          plugins: [atom() | {atom(), keyword()} | module()],
          transformers: [atom() | {atom(), keyword()} | module()],
          tools: [map()] | nil,
          tape_name: String.t() | nil,
          tape_module: module(),
          agent_name: atom(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          workspace: String.t() | nil,
          depth: non_neg_integer(),
          subagent: boolean(),
          user_id: String.t() | nil,
          organization_id: String.t() | nil,
          emit: (map() -> :ok) | nil,
          description: String.t() | nil,
          skills: [term()],
          avatar: String.t() | nil,
          sandbox_enabled: boolean(),
          lite: boolean()
        }

  @defaults %{
    system_prompt: "You are a helpful assistant.",
    max_steps: 50,
    max_tokens: 4096,
    compact_threshold: 100_000,
    plugins: [],
    transformers: [],
    tools: nil,
    turn_strategy: Rho.TurnStrategy.Direct,
    prompt_format: :markdown,
    tape_module: Rho.Tape.Projection.JSONL,
    agent_name: :default,
    depth: 0,
    subagent: false,
    description: nil,
    skills: [],
    avatar: nil,
    sandbox_enabled: false,
    lite: false
  }

  @doc """
  Build a RunSpec from keyword options, filling in sensible defaults.

  The only required option is `:model`.

  ## Examples

      Rho.RunSpec.build(model: "openrouter:anthropic/claude-sonnet")

      Rho.RunSpec.build(
        model: "mock:test",
        plugins: [:bash, :fs_read],
        max_steps: 5,
        system_prompt: "You are a code assistant."
      )
  """
  @spec build(keyword()) :: t()
  def build(opts) when is_list(opts) do
    model = opts[:model] || raise ArgumentError, "RunSpec.build requires :model"

    struct!(
      __MODULE__,
      Map.merge(@defaults, %{model: model})
      |> Map.merge(Map.new(opts))
    )
  end
end
