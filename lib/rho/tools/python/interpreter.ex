defmodule Rho.Tools.Python.Interpreter do
  @moduledoc """
  Per-session Python interpreter GenServer.

  Maintains Python globals across tool calls within a session,
  giving the agent a stateful REPL experience. Each session gets
  its own interpreter identified by a session_id key.

  State is maintained on the Python side via a dedicated module
  namespace, avoiding passing Pythonx.Object globals back through
  the NIF (which can cause bus errors on some platforms).
  """

  use GenServer

  require Logger

  # Bootstrap code creates a Python module registered in sys.modules,
  # so we never need to pass Pythonx.Object globals back to the NIF.
  @init_code """
  import types as _t, sys as _s
  _s.modules['__rho_ns'] = _t.ModuleType('__rho_ns')
  _s.modules['__rho_ns'].__dict__['__builtins__'] = __builtins__
  del _t, _s
  try:
      import matplotlib
      matplotlib.use('Agg')
  except ImportError:
      pass
  """

  # --- Public API ---

  @doc "Start a named interpreter for the given session."
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: via(session_id)
    )
  end

  @doc """
  Evaluate Python code in the session's interpreter.

  Returns {:ok, output} or {:error, reason} where output includes
  both captured stdout/stderr and the expression result.
  """
  def eval(session_id, code, workspace \\ nil) do
    case whereis(session_id) do
      nil -> start_and_eval(session_id, code, workspace)
      pid -> GenServer.call(pid, {:eval, code}, :infinity)
    end
  end

  @doc "Return basic session info if the interpreter is running."
  def session_info(session_id) do
    case whereis(session_id) do
      nil -> :error
      _pid -> {:ok, [variable_count: 0]}
    end
  end

  @doc "Stop the interpreter for the given session."
  def stop(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    workspace = Keyword.get(opts, :workspace)
    {:ok, %{initialized: false, workspace: workspace}}
  end

  @impl true
  def handle_call({:eval, code}, _from, state) do
    {state, init_error} = maybe_init_namespace(state)

    case init_error do
      nil ->
        {result, new_state} = do_eval(code, state)
        {:reply, result, new_state}

      error ->
        {:reply, error, state}
    end
  end

  # --- Private ---

  defp maybe_init_namespace(%{initialized: true} = state), do: {state, nil}

  defp maybe_init_namespace(state) do
    Logger.debug("[PythonInterpreter] initializing Python namespace")

    try do
      Pythonx.eval(@init_code, %{})

      # Set working directory if workspace is configured
      if state.workspace do
        chdir_code = "import os; os.chdir(#{python_string_literal(state.workspace)})"
        Pythonx.eval(chdir_code, %{})
      end

      {%{state | initialized: true}, nil}
    rescue
      e ->
        Logger.error("[PythonInterpreter] namespace init failed: #{Exception.message(e)}")
        {state, {:error, "Python init failed: #{Exception.message(e)}"}}
    end
  end

  defp do_eval(code, state) do
    Logger.debug("[PythonInterpreter] eval start | code_bytes=#{byte_size(code)}")
    Logger.debug("[PythonInterpreter] code:\n#{String.slice(code, 0, 500)}")

    # Wrap user code to execute inside the persistent namespace.
    # Uses ast to split out the last expression (if any) so we can
    # capture its value — similar to how Jupyter/IPython works.
    wrapped_code = """
    import sys as __s, ast as __a
    __rho_ns = __s.modules['__rho_ns'].__dict__
    __rho_tree = __a.parse(#{python_string_literal(code)}, '<rho>')
    __rho_result = None
    if __rho_tree.body and isinstance(__rho_tree.body[-1], __a.Expr):
        __rho_last = __rho_tree.body.pop()
        if __rho_tree.body:
            exec(compile(__a.fix_missing_locations(__a.Module(body=__rho_tree.body, type_ignores=[])), '<rho>', 'exec'), __rho_ns)
        __rho_result = eval(compile(__a.fix_missing_locations(__a.Expression(body=__rho_last.value)), '<rho>', 'eval'), __rho_ns)
    else:
        exec(compile(__rho_tree, '<rho>', 'exec'), __rho_ns)
    del __a, __rho_tree, __rho_ns
    # Normalize to structured response: {"final": bool, "result": value}
    # If the code already returned this structure, use it as-is.
    # Otherwise, wrap the result with final=True (default: show to user).
    if isinstance(__rho_result, dict) and "final" in __rho_result and "result" in __rho_result:
        __rho_final = __rho_result
    elif __rho_result is not None:
        __rho_final = {"final": True, "result": __rho_result}
    else:
        __rho_final = None
    del __rho_result, __s
    __rho_final
    """

    # Snapshot files in workspace before execution to detect created/modified files
    workspace = state.workspace
    files_before = if workspace, do: snapshot_files(workspace), else: %{}

    try do
      {:ok, string_io} = StringIO.open("")

      Logger.debug("[PythonInterpreter] calling Pythonx.eval...")

      {result, _updated_globals} =
        Pythonx.eval(wrapped_code, %{}, stdout_device: string_io)

      Logger.debug("[PythonInterpreter] Pythonx.eval returned")

      # Capture any open matplotlib figures and save as PNG files
      image_paths = capture_matplotlib_figures(workspace)

      {_, {_, stdout}} = StringIO.close(string_io)
      Logger.debug("[PythonInterpreter] stdout_bytes=#{byte_size(stdout)}")

      changed_files = if workspace, do: detect_changed_files(workspace, files_before), else: []
      {disposition, output} = format_output(String.trim_trailing(stdout), result, changed_files, image_paths)
      {{disposition, output}, state}
    rescue
      e in [Pythonx.Error] ->
        Logger.error("[PythonInterpreter] Pythonx.Error: #{Exception.message(e)}")
        {{:error, Exception.message(e)}, state}

      e ->
        Logger.error("[PythonInterpreter] unexpected error: #{Exception.message(e)}")
        {{:error, "Python eval failed: #{Exception.message(e)}"}, state}
    end
  end

  # Capture any open matplotlib figures, save as PNG files, then close them.
  # Returns a list of file paths where images were saved.
  defp capture_matplotlib_figures(workspace) do
    output_dir = workspace || System.tmp_dir!()

    capture_code = """
    __rho_paths = []
    try:
        import matplotlib.pyplot as __rho_plt
        import time as __rho_time
        __rho_ts = int(__rho_time.time() * 1000)
        for __rho_i, __rho_fnum in enumerate(__rho_plt.get_fignums()):
            __rho_fig = __rho_plt.figure(__rho_fnum)
            __rho_path = #{python_string_literal(output_dir)} + f"/plot_{__rho_ts}_{__rho_i + 1}.png"
            __rho_fig.savefig(__rho_path, format='png', bbox_inches='tight', dpi=150)
            __rho_paths.append(__rho_path)
        __rho_plt.close('all')
        del __rho_plt, __rho_time, __rho_ts, __rho_fig, __rho_fnum, __rho_i, __rho_path
    except ImportError:
        pass
    except Exception:
        pass
    __rho_paths
    """

    try do
      {result, _} = Pythonx.eval(capture_code, %{})
      decoded = Pythonx.decode(result)
      if is_list(decoded), do: decoded, else: []
    rescue
      _ -> []
    end
  end

  defp format_output(stdout, result, changed_files, image_paths) do
    decoded =
      try do
        Pythonx.decode(result)
      rescue
        _ -> nil
      end

    image_tags = Enum.map(image_paths, &"[Plot saved: #{&1}]")

    # Check for structured response: {"final": bool, "result": value}
    case decoded do
      %{"final" => final?, "result" => value} when is_boolean(final?) ->
        disposition = if final?, do: :final, else: :ok
        result_str = if is_binary(value), do: value, else: inspect(value)

        parts =
          [
            if(stdout != "", do: stdout),
            result_str,
            format_changed_files(changed_files)
          ]
          |> Enum.reject(&is_nil/1)
          |> Kernel.++(image_tags)

        {disposition, Enum.join(parts, "\n")}

      _ ->
        parts =
          [
            if(stdout != "", do: stdout),
            if(decoded != nil, do: inspect(decoded)),
            format_changed_files(changed_files)
          ]
          |> Enum.reject(&is_nil/1)
          |> Kernel.++(image_tags)

        output = if parts == [], do: "(code executed successfully, no output)", else: Enum.join(parts, "\n")
        {:ok, output}
    end
  end

  defp format_changed_files([]), do: nil
  defp format_changed_files(files), do: "Files written: #{Enum.join(files, ", ")}"

  # Escape user code into a Python triple-quoted raw string literal.
  defp python_string_literal(code) do
    # Use a triple-quoted string with backslash escaping for safety.
    escaped =
      code
      |> String.replace("\\", "\\\\")
      |> String.replace("\"\"\"", "\\\"\\\"\\\"")

    ~s("""#{escaped}""")
  end

  defp start_and_eval(session_id, code, workspace) do
    case DynamicSupervisor.start_child(
           Rho.Tools.Python.Supervisor,
           {__MODULE__, session_id: session_id, workspace: workspace}
         ) do
      {:ok, _pid} -> GenServer.call(via(session_id), {:eval, code}, :infinity)
      {:error, {:already_started, _pid}} -> GenServer.call(via(session_id), {:eval, code}, :infinity)
      {:error, reason} -> {:error, "Failed to start Python interpreter: #{inspect(reason)}"}
    end
  end

  defp via(session_id) do
    {:via, Registry, {Rho.PythonRegistry, session_id}}
  end

  defp whereis(session_id) do
    case Registry.lookup(Rho.PythonRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Snapshot mtime of files in the workspace directory (non-recursive, top-level only)
  defp snapshot_files(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        Map.new(entries, fn name ->
          path = Path.join(workspace, name)
          mtime = case File.stat(path) do
            {:ok, %{mtime: mtime}} -> mtime
            _ -> nil
          end
          {name, mtime}
        end)

      _ ->
        %{}
    end
  end

  # Return list of filenames that were created or modified since the snapshot
  defp detect_changed_files(workspace, before) do
    # Reuse snapshot_files to get current state, then diff against before
    after_snapshot = snapshot_files(workspace)

    after_snapshot
    |> Enum.filter(fn {name, mtime} -> Map.get(before, name) != mtime end)
    |> Enum.map(&elem(&1, 0))
  end
end
