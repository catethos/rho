defmodule Rho.Stdlib.Tools.Python.Interpreter do
  @moduledoc """
  Per-session Python interpreter GenServer.

  Maintains Python state across tool calls within a session, giving
  the agent a stateful Jupyter-style REPL. Each session gets its own
  interpreter identified by a session_id key.

  State lives in a Python dict (`__rho_ns`) owned by this GenServer's
  per-process erlang_python environment. Since erlang_python's
  process-bound env is keyed by `{ContextPid, ErlangPid}`, terminating
  the GenServer drops all Python state for that session.
  """

  use GenServer

  require Logger

  # Bootstrap installs the per-session namespace dict + helper functions
  # into the GenServer's process-bound Python env. Helpers are referenced
  # by all subsequent eval calls.
  @bootstrap_code """
  import sys, ast, io, traceback

  __rho_ns = {'__builtins__': __builtins__}

  try:
      import matplotlib
      matplotlib.use('Agg')
  except ImportError:
      pass


  def __rho_exec(user_code):
      captured = io.StringIO()
      orig = sys.stdout
      sys.stdout = captured
      result = None
      error = None
      try:
          tree = ast.parse(user_code, '<rho>')
          if tree.body and isinstance(tree.body[-1], ast.Expr):
              last = tree.body.pop()
              if tree.body:
                  exec(
                      compile(
                          ast.fix_missing_locations(
                              ast.Module(body=tree.body, type_ignores=[])
                          ),
                          '<rho>',
                          'exec',
                      ),
                      __rho_ns,
                  )
              result = eval(
                  compile(
                      ast.fix_missing_locations(ast.Expression(body=last.value)),
                      '<rho>',
                      'eval',
                  ),
                  __rho_ns,
              )
          else:
              exec(compile(tree, '<rho>', 'exec'), __rho_ns)
      except BaseException:
          error = traceback.format_exc()
      finally:
          sys.stdout = orig

      if error is not None:
          return {'stdout': captured.getvalue(), 'error': error}

      if isinstance(result, dict) and 'final' in result and 'result' in result:
          final = result
      elif result is not None:
          final = {'final': True, 'result': result}
      else:
          final = None

      return {'stdout': captured.getvalue(), 'result': final}


  def __rho_capture_figures(output_dir):
      paths = []
      try:
          import matplotlib.pyplot as plt
          import time
          ts = int(time.time() * 1000)
          for i, fnum in enumerate(plt.get_fignums()):
              fig = plt.figure(fnum)
              p = output_dir + '/plot_' + str(ts) + '_' + str(i + 1) + '.png'
              fig.savefig(p, format='png', bbox_inches='tight', dpi=150)
              paths.append(p)
          plt.close('all')
      except ImportError:
          pass
      except Exception:
          pass
      return paths
  """

  # --- Public API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc """
  Evaluate Python code in the session's interpreter. Returns
  `{disposition, output}` where disposition is `:ok | :final | :error`.
  """
  def eval(session_id, code, workspace \\ nil) do
    case whereis(session_id) do
      nil -> start_and_eval(session_id, code, workspace)
      pid -> GenServer.call(pid, {:eval, code}, :timer.minutes(5))
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
    # Pin a context so every call from this GenServer routes to the
    # same erlang_python worker — that's where __rho_ns lives.
    ctx = :py.context()
    {:ok, %{initialized?: false, workspace: workspace, ctx: ctx}}
  end

  @impl true
  def handle_call({:eval, code}, _from, state) do
    case ensure_bootstrap(state) do
      {:ok, state} ->
        files_before =
          if state.workspace, do: snapshot_files(state.workspace), else: %{}

        case :py.eval(state.ctx, "__rho_exec(__user_code)", %{__user_code: code}) do
          {:ok, response} ->
            image_paths = capture_matplotlib_figures(state)

            changed_files =
              if state.workspace,
                do: detect_changed_files(state.workspace, files_before),
                else: []

            {:reply, build_reply(response, changed_files, image_paths), state}

          {:error, reason} ->
            {:reply, {:error, {:eval_failed, format_py_error(reason)}}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # --- Private ---

  defp ensure_bootstrap(%{initialized?: true} = state), do: {:ok, state}

  defp ensure_bootstrap(state) do
    Logger.debug("[PythonInterpreter] bootstrapping namespace")

    case :py.exec(state.ctx, @bootstrap_code) do
      :ok ->
        case maybe_chdir(state) do
          :ok -> {:ok, %{state | initialized?: true}}
          {:error, _} = err -> err
        end

      {:error, reason} ->
        Logger.error("[PythonInterpreter] bootstrap failed: #{inspect(reason)}")
        {:error, {:init_failed, "Python bootstrap failed: #{format_py_error(reason)}"}}
    end
  end

  defp maybe_chdir(%{workspace: nil}), do: :ok

  defp maybe_chdir(%{workspace: workspace, ctx: ctx}) do
    case :py.exec(
           ctx,
           "import os; os.chdir(#{python_string_literal(workspace)})"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:init_failed, format_py_error(reason)}}
    end
  end

  defp capture_matplotlib_figures(state) do
    output_dir = state.workspace || System.tmp_dir!()

    case :py.eval(
           state.ctx,
           "__rho_capture_figures(__output_dir)",
           %{__output_dir: output_dir}
         ) do
      {:ok, paths} when is_list(paths) -> paths
      _ -> []
    end
  end

  defp build_reply(%{"error" => traceback, "stdout" => stdout}, _changed, _images) do
    msg =
      [stdout, traceback]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.join("\n")

    {:error, {:eval_failed, msg}}
  end

  defp build_reply(%{"result" => result, "stdout" => stdout}, changed, images) do
    stdout = String.trim_trailing(stdout || "")
    image_tags = Enum.map(images, &"[Plot saved: #{&1}]")

    case result do
      %{"final" => final?, "result" => value} when is_boolean(final?) ->
        format_structured_output(stdout, final?, value, changed, image_tags)

      _ ->
        format_plain_output(stdout, result, changed, image_tags)
    end
  end

  defp format_structured_output(stdout, final?, value, changed_files, image_tags) do
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
  end

  defp format_plain_output(stdout, result, changed_files, image_tags) do
    parts =
      [
        if(stdout != "", do: stdout),
        if(result != nil and result != :none, do: inspect(result)),
        format_changed_files(changed_files)
      ]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(image_tags)

    output =
      if parts == [],
        do: "(code executed successfully, no output)",
        else: Enum.join(parts, "\n")

    {:ok, output}
  end

  defp format_changed_files([]), do: nil
  defp format_changed_files(files), do: "Files written: #{Enum.join(files, ", ")}"

  defp format_py_error({exc_type, msg}), do: "#{exc_type}: #{msg}"
  defp format_py_error(other), do: inspect(other)

  defp python_string_literal(s) when is_binary(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp start_and_eval(session_id, code, workspace) do
    case DynamicSupervisor.start_child(
           Rho.Stdlib.Tools.Python.Supervisor,
           {__MODULE__, session_id: session_id, workspace: workspace}
         ) do
      {:ok, _pid} ->
        GenServer.call(via(session_id), {:eval, code}, :timer.minutes(5))

      {:error, {:already_started, _pid}} ->
        GenServer.call(via(session_id), {:eval, code}, :timer.minutes(5))

      {:error, reason} ->
        {:error, {:start_failed, "Failed to start Python interpreter: #{inspect(reason)}"}}
    end
  end

  defp via(session_id), do: {:via, Registry, {Rho.PythonRegistry, session_id}}

  defp whereis(session_id) do
    case Registry.lookup(Rho.PythonRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp snapshot_files(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        Map.new(entries, fn name -> {name, file_mtime(Path.join(workspace, name))} end)

      _ ->
        %{}
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp detect_changed_files(workspace, before) do
    after_snapshot = snapshot_files(workspace)

    after_snapshot
    |> Enum.filter(fn {name, mtime} -> Map.get(before, name) != mtime end)
    |> Enum.map(&elem(&1, 0))
  end
end