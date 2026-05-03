defmodule RhoEmbeddings.Server do
  @moduledoc false
  # Singleton GenServer owning the loaded embedding model.
  #
  # All embed_many/1 calls funnel through here so they serialize against
  # pythonx's GIL. The actual model load + eval calls go through the
  # configured backend (Pythonx in prod, Fake in tests).

  use GenServer

  require Logger

  @default_model "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
  @embed_timeout :timer.seconds(60)

  # --- Public API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def embed_many(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_many, texts}, @embed_timeout)
  end

  def ready?(), do: GenServer.call(__MODULE__, :ready?)

  def model_name(), do: GenServer.call(__MODULE__, :model_name)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      model_name: configured_model(),
      backend: configured_backend(),
      enabled?: enabled?(),
      loaded?: false,
      load_error: nil,
      load_task: nil
    }

    if state.enabled? do
      task = Task.async(fn -> state.backend.load(state.model_name) end)
      {:ok, %{state | load_task: task}}
    else
      Logger.info("RhoEmbeddings disabled (RHO_EMBEDDINGS_ENABLED=false)")
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.loaded?, state}

  def handle_call(:model_name, _from, state), do: {:reply, state.model_name, state}

  def handle_call({:embed_many, _texts}, _from, %{enabled?: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:embed_many, _texts}, _from, %{loaded?: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:embed_many, texts}, _from, state) do
    {:reply, state.backend.embed(texts), state}
  end

  @impl true
  def handle_info({ref, result}, %{load_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        Logger.info("RhoEmbeddings model loaded: #{state.model_name}")
        {:noreply, %{state | loaded?: true, load_task: nil}}

      {:error, reason} ->
        Logger.error("RhoEmbeddings model load failed: #{inspect(reason)}")
        {:noreply, %{state | load_error: reason, load_task: nil}}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, %{load_task: %Task{}} = state) do
    Logger.error("RhoEmbeddings load task crashed: #{inspect(reason)}")
    {:noreply, %{state | load_error: reason, load_task: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp configured_model() do
    Application.get_env(:rho_embeddings, :model, @default_model)
  end

  defp configured_backend() do
    Application.get_env(:rho_embeddings, :backend, RhoEmbeddings.Backend.OpenAI)
  end

  defp enabled?() do
    Application.get_env(:rho_embeddings, :enabled, true)
  end
end
