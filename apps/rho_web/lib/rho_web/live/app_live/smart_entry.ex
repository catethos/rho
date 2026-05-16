defmodule RhoWeb.AppLive.SmartEntry do
  @moduledoc """
  Owns the smart natural-language entry flow for `RhoWeb.AppLive`.

  The module keeps the LiveView shell thin: submit text to the flow-intent
  classifier, receive the async result, and either start a chat-hosted flow,
  navigate to a route-backed flow, or explain why the entry stayed put.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  alias RhoWeb.AppLive.FlowSession

  @min_confidence 0.5
  @allowed_starting_points ~w(from_template scratch extend_existing merge)

  def handle_event("smart_entry_submit", %{"message" => msg}, socket)
      when is_binary(msg) and msg != "" do
    parent = self()
    classifier = match_flow_intent_mod()

    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      result = classifier.call(%{message: String.trim(msg), known_flows: known_flows_string()})
      send(parent, {:smart_entry_result, msg, result})
    end)

    {:noreply, assign(socket, :smart_entry_pending?, true)}
  end

  def handle_event("smart_entry_submit", _params, socket) do
    {:noreply, socket}
  end

  def handle_info({:smart_entry_result, message, result}, socket) do
    {:noreply, dispatch_result(socket, message, result)}
  end

  def dispatch_result(socket, _message, {:ok, %{flow_id: flow_id} = result}) do
    confidence = Map.get(result, :confidence, 0.0)

    case RhoFrameworks.Flows.Registry.get(flow_id) do
      {:ok, _flow_mod} when flow_id == "create-framework" and confidence >= @min_confidence ->
        org = socket.assigns.current_organization

        socket
        |> assign(:smart_entry_pending?, false)
        |> FlowSession.start(flow_id, build_intake(result, org.id))

      {:ok, _flow_mod} when confidence >= @min_confidence ->
        org = socket.assigns.current_organization
        query = build_intake_query(result, org.id)

        url =
          if query == "" do
            "/orgs/#{org.slug}/flows/#{flow_id}"
          else
            "/orgs/#{org.slug}/flows/#{flow_id}?#{query}"
          end

        socket |> assign(:smart_entry_pending?, false) |> push_navigate(to: url)

      _ ->
        reasoning =
          case Map.get(result, :reasoning) do
            s when is_binary(s) and s != "" -> s
            _ -> "Could not match the message to a known flow."
          end

        socket
        |> assign(:smart_entry_pending?, false)
        |> put_flash(:info, reasoning <> " Try describing the workflow in chat, or rephrase.")
    end
  end

  def dispatch_result(socket, _message, {:error, reason}) do
    Logger.warning(fn -> "[AppLive] smart_entry classifier failed: #{inspect(reason)}" end)

    socket
    |> assign(:smart_entry_pending?, false)
    |> put_flash(:error, "Couldn't process that - try describing the workflow in chat.")
  end

  def dispatch_result(socket, _message, _other) do
    socket
    |> assign(:smart_entry_pending?, false)
    |> put_flash(:error, "Unexpected response - try again.")
  end

  def build_intake_query(result, org_id) do
    result
    |> build_intake(org_id)
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> URI.encode_query()
  end

  def build_intake(result, org_id) do
    [:name, :description, :domain, :target_roles]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(result, key) do
        v when is_binary(v) and v != "" -> Map.put(acc, key, v)
        _ -> acc
      end
    end)
    |> maybe_put_starting_point_value(result)
    |> maybe_put_library_id_values(result, org_id)
  end

  def resolve_library_hints(hints, libraries) when is_list(hints) do
    Enum.flat_map(hints, fn hint -> List.wrap(resolve_one_hint(hint, libraries)) end)
  end

  def resolve_library_hints(_, _) do
    []
  end

  def known_flows_string do
    "- create-framework - Build a brand-new skill framework from scratch (with optional similar-role lookup or domain research). Use when the user wants to design or generate a new framework.
- edit-framework - Edit an existing framework in place: tweak skill names, descriptions, categories, then save back to the same library. Use when the user wants to change/update/fix/edit one of their existing frameworks. Requires a library_hint naming which framework to edit.
"
  end

  defp maybe_put_starting_point_value(intake, result) do
    case Map.get(result, :starting_point) do
      sp when sp in @allowed_starting_points -> Map.put(intake, :starting_point, sp)
      _ -> intake
    end
  end

  defp maybe_put_library_id_values(intake, result, org_id) do
    hints = Map.get(result, :library_hints, [])

    libraries =
      if is_binary(org_id) and hints != [] do
        RhoFrameworks.Library.list_libraries(org_id)
      else
        []
      end

    case resolve_library_hints(hints, libraries) do
      [id] -> Map.put(intake, :library_id, id)
      [id_a, id_b] -> intake |> Map.put(:library_id_a, id_a) |> Map.put(:library_id_b, id_b)
      _ -> intake
    end
  end

  defp resolve_one_hint(hint, libraries) when is_binary(hint) and hint != "" do
    hint_down = String.downcase(hint)
    matches = Enum.filter(libraries, fn %{name: name} -> String.downcase(name) =~ hint_down end)

    case matches do
      [%{id: id}] -> id
      _ -> nil
    end
  end

  defp resolve_one_hint(_, _) do
    nil
  end

  defp match_flow_intent_mod do
    Application.get_env(:rho_web, :match_flow_intent_mod, RhoFrameworks.LLM.MatchFlowIntent)
  end
end
