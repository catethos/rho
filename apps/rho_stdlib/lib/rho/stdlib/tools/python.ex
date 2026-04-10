defmodule Rho.Stdlib.Tools.Python do
  @moduledoc """
  Python REPL tool powered by Pythonx.

  Provides a stateful Python interpreter per session. Variables and imports
  persist across calls within the same session, giving the agent a true REPL.
  """

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_mount_opts, %{tape_name: tape_name, workspace: workspace}),
    do: [tool_def(tape_name, workspace)]

  def tools(_mount_opts, %{tape_name: tape_name}), do: [tool_def(tape_name, nil)]
  def tools(_mount_opts, _context), do: []

  @impl Rho.Plugin
  def bindings(_mount_opts, %{tape_name: tape_name} = _context) do
    case Rho.Stdlib.Tools.Python.Interpreter.session_info(tape_name) do
      {:ok, info} ->
        [
          %{
            name: "python_repl",
            kind: :session_state,
            size: info[:variable_count] || 0,
            access: :python_var,
            persistence: :session,
            summary: "Python REPL session with #{info[:variable_count] || 0} variables"
          }
        ]

      _ ->
        []
    end
  end

  def bindings(_mount_opts, _context), do: []

  defp tool_def(session_id, workspace) do
    %{
      tool:
        ReqLLM.tool(
          name: "python",
          description: """
          Execute Python code in a persistent REPL. Variables, imports, and state \
          are preserved across calls within this session. \
          Python packages specified in the project config are available for import. \
          Matplotlib is available — any open figures are automatically captured and \
          displayed after execution. Just create your plot; no need to call plt.show() \
          or plt.savefig().

          REPL rules: all variables persist across calls. NEVER re-type or \
          duplicate data already stored in a variable — just reference it by name. \
          Wrong: `A = [1,2,3]; [x+1 for x in A]`. Right: `[x+1 for x in A]` \
          (when A was defined in a previous call).

          By default, the result of the last expression is returned directly to \
          the user as the final answer. If you need to process the result further \
          in subsequent steps (e.g. intermediate computation, data preparation), \
          make your last expression: {"final": False, "result": value}\
          """,
          parameter_schema: [
            code: [type: :string, required: true, doc: "Python code to execute"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx -> execute(args, session_id, workspace) end
    }
  end

  defp execute(%{"code" => code}, session_id, workspace),
    do: execute(%{code: code}, session_id, workspace)

  defp execute(%{code: code}, session_id, workspace) do
    Rho.Stdlib.Tools.Python.Interpreter.eval(session_id, code, workspace)
  end
end
