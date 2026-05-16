defmodule RhoWeb.AppLiveSmartEntryTest do
  @moduledoc """
  Tests for the Phase 9 smart-NL entry routing in `AppLive`. Exercises
  the `handle_info({:smart_entry_result, ...})` dispatch directly with
  a sparse socket — the BAML classifier itself is bypassed (the whole
  point of the seam) and the spawn path is covered by integration
  rather than unit tests.
  """

  use ExUnit.Case, async: false

  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.{Library, Repo}
  alias Rho.Stdlib.DataTable

  defp build_socket(assigns_override) do
    sid = "smart_entry_test_#{System.unique_integer([:positive])}"
    agent_id = Rho.Agent.Primary.agent_id(sid)
    on_exit(fn -> DataTable.stop(sid) end)

    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{},
          smart_entry_pending?: true,
          session_id: sid,
          active_agent_id: agent_id,
          agent_messages: %{agent_id => []},
          next_id: 1,
          active_page: :chat,
          active_flow: nil,
          current_user: %{id: Ecto.UUID.generate()}
        },
        assigns_override
      )

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  defp org, do: %{id: Ecto.UUID.generate(), slug: "acme", name: "Acme"}

  defp create_org do
    org_id = Ecto.UUID.generate()
    slug = "smart-entry-#{System.unique_integer([:positive])}"
    Repo.insert!(%Organization{id: org_id, name: "Smart Entry Org", slug: slug})
    %{id: org_id, slug: slug, name: "Smart Entry Org"}
  end

  defp ok_result(overrides) do
    base = %{
      flow_id: "create-framework",
      confidence: 0.9,
      reasoning: "Looks like a from-scratch framework build.",
      name: "",
      description: "",
      domain: "",
      target_roles: ""
    }

    base
    |> Map.merge(%{starting_point: "", library_hints: []})
    |> Map.merge(overrides)
    |> then(&{:ok, &1})
  end

  defp assert_create_flow_started(socket, expected_intake \\ %{}) do
    refute socket.redirected
    assert socket.assigns.smart_entry_pending? == false
    assert socket.assigns.active_flow.id == "create-framework"
    assert socket.assigns.active_flow.runner.node_id == :choose_starting_point

    Enum.each(expected_intake, fn {key, value} ->
      assert socket.assigns.active_flow.runner.intake[key] == value
    end)

    agent_id = socket.assigns.active_agent_id

    assert [%{type: :flow_card, flow: %{node_id: :choose_starting_point}}] =
             socket.assigns.agent_messages[agent_id]
  end

  describe "handle_info :smart_entry_result — edit-framework routing" do
    test "navigates to edit-framework with library_id when hint resolves" do
      org = create_org()
      {:ok, lib} = Library.create_library(org.id, %{name: "SFIA Framework"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "edit our SFIA framework",
           ok_result(%{flow_id: "edit-framework", library_hints: ["SFIA"]})},
          socket
        )

      assert {:live, :redirect, %{to: url}} = after_socket.redirected
      assert url =~ "/flows/edit-framework?"
      assert url =~ "library_id=#{lib.id}"
    end

    test "navigates to edit-framework even without library_id (user picks manually)" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "edit a framework",
           ok_result(%{flow_id: "edit-framework", library_hints: []})},
          socket
        )

      assert {:live, :redirect, %{to: url}} = after_socket.redirected
      assert url =~ "/flows/edit-framework"
      refute url =~ "library_id"
    end

    test "edit-framework with unresolvable hint still navigates (without library_id)" do
      org = create_org()
      {:ok, _lib} = Library.create_library(org.id, %{name: "Real Lib"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "edit our nonexistent framework",
           ok_result(%{flow_id: "edit-framework", library_hints: ["Nonexistent"]})},
          socket
        )

      assert {:live, :redirect, %{to: url}} = after_socket.redirected
      assert url =~ "/flows/edit-framework"
      refute url =~ "library_id"
    end
  end

  describe "handle_info :smart_entry_result — high-confidence routing" do
    test "starts a chat-hosted flow with intake prefilled" do
      socket = build_socket(%{current_organization: org()})

      result =
        ok_result(%{
          name: "Backend Engineering",
          description: "Skills for backend engineers",
          target_roles: "Backend Engineer, Tech Lead"
        })

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info({:smart_entry_result, "build it", result}, socket)

      assert_create_flow_started(after_socket, %{
        name: "Backend Engineering",
        description: "Skills for backend engineers",
        target_roles: "Backend Engineer, Tech Lead"
      })
    end

    test "starts a chat-hosted flow when no intake fields were extracted" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "make a framework", ok_result(%{})},
          socket
        )

      assert_create_flow_started(after_socket)
    end
  end

  describe "handle_info :smart_entry_result — fallback paths" do
    test "low confidence stays on the page and clears pending" do
      socket = build_socket(%{current_organization: org()})

      result =
        ok_result(%{
          flow_id: "create-framework",
          confidence: 0.2,
          reasoning: "Vague request, not sure which flow."
        })

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info({:smart_entry_result, "vague", result}, socket)

      assert after_socket.assigns.smart_entry_pending? == false
      refute after_socket.redirected
      assert after_socket.assigns.flash["info"] =~ "Vague request"
    end

    test "unknown flow_id stays on the page even with high confidence" do
      socket = build_socket(%{current_organization: org()})

      result =
        ok_result(%{
          flow_id: "unknown",
          confidence: 0.9,
          reasoning: "Doesn't match any known flow."
        })

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info({:smart_entry_result, "off-topic", result}, socket)

      assert after_socket.assigns.smart_entry_pending? == false
      refute after_socket.redirected
      assert after_socket.assigns.flash["info"] =~ "Doesn't match"
    end

    test "low confidence with nil reasoning falls back to a default flash (no crash)" do
      # Regression: :reasoning is Zoi.optional(), so the LLM may omit it
      # and BAML returns the struct with reasoning: nil. Map.get returns
      # nil (not the default) when the key is present-but-nil, so the
      # naive `Map.get(result, :reasoning, default)` would crash on the
      # subsequent `<>` concat.
      socket = build_socket(%{current_organization: org()})

      result = %RhoFrameworks.LLM.MatchFlowIntent{
        flow_id: "create-framework",
        confidence: 0.2,
        reasoning: nil,
        name: nil,
        description: nil,
        domain: nil,
        target_roles: nil,
        starting_point: nil,
        library_hints: nil
      }

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info({:smart_entry_result, "vague", {:ok, result}}, socket)

      assert after_socket.assigns.smart_entry_pending? == false
      refute after_socket.redirected
      assert after_socket.assigns.flash["info"] =~ "Could not match"
    end

    test ":error result flashes and clears pending" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "anything", {:error, :timeout}},
          socket
        )

      assert after_socket.assigns.smart_entry_pending? == false
      refute after_socket.redirected
      assert after_socket.assigns.flash["error"] =~ "try describing the workflow in chat"
    end
  end

  describe "library page chat entry" do
    test "renders Open in Chat as a main chat route with library_id" do
      org = org()
      library_id = Ecto.UUID.generate()

      assigns = %{
        __changed__: %{},
        active_page: :library_show,
        current_organization: org,
        current_user: nil,
        library: %{
          id: library_id,
          name: "CEO Skill Framework",
          description: "Reusable skill taxonomy",
          version: nil,
          is_default: false,
          immutable: true,
          derived_from_id: nil
        },
        fork_pending?: false,
        show_fork_modal: false,
        fork_name: "",
        show_diff: false,
        diff_result: nil,
        research_notes: [],
        status_filter: nil,
        skill_search_query: "",
        skill_search_active?: false,
        search_grouped: [],
        filtered_skill_count: 0,
        total_skill_count: 0,
        grouped_index: [],
        grouped: %{},
        all_skills_loaded?: true,
        highlight_skill: nil,
        open_categories: MapSet.new(),
        open_clusters: MapSet.new(),
        cluster_skills: %{}
      }

      html =
        assigns
        |> RhoWeb.AppLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "/orgs/#{org.slug}/chat?library_id=#{library_id}"
      refute html =~ "ChatOverlayComponent"
      refute html =~ "?chat=1"
    end
  end

  describe "handle_info :smart_entry_result — Phase 10d starting_point" do
    test "valid starting_point lands in flow intake" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "from scratch please", ok_result(%{starting_point: "scratch"})},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "scratch"})
    end

    test "all four valid starting_point values pass the whitelist" do
      for sp <- ~w(from_template scratch extend_existing merge) do
        socket = build_socket(%{current_organization: org()})

        {:noreply, after_socket} =
          RhoWeb.AppLive.handle_info(
            {:smart_entry_result, "msg", ok_result(%{starting_point: sp})},
            socket
          )

        assert_create_flow_started(after_socket, %{starting_point: sp})
      end
    end

    test "empty starting_point is dropped" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "vague", ok_result(%{starting_point: ""})},
          socket
        )

      assert_create_flow_started(after_socket)
      refute Map.has_key?(after_socket.assigns.active_flow.runner.intake, :starting_point)
    end

    test "garbage starting_point is rejected by the whitelist" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "msg", ok_result(%{starting_point: "DROP TABLE users"})},
          socket
        )

      assert_create_flow_started(after_socket)
      refute Map.has_key?(after_socket.assigns.active_flow.runner.intake, :starting_point)
    end
  end

  describe "handle_info :smart_entry_result — Phase 10d/10e library_hints resolution" do
    test "single unique substring match resolves to library_id" do
      org = create_org()
      {:ok, _lib} = Library.create_library(org.id, %{name: "SFIA Framework v8"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "like our SFIA framework",
           ok_result(%{starting_point: "extend_existing", library_hints: ["SFIA"]})},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "extend_existing"})
      assert after_socket.assigns.active_flow.runner.intake[:library_id]
    end

    test "case-insensitive substring matching" do
      org = create_org()
      {:ok, lib} = Library.create_library(org.id, %{name: "Backend Engineering Skills"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "extend backend",
           ok_result(%{starting_point: "extend_existing", library_hints: ["BACKEND"]})},
          socket
        )

      assert_create_flow_started(after_socket, %{
        starting_point: "extend_existing",
        library_id: lib.id
      })
    end

    test "ambiguous hint (multiple matches) is dropped silently" do
      org = create_org()
      {:ok, _} = Library.create_library(org.id, %{name: "Design System"})
      {:ok, _} = Library.create_library(org.id, %{name: "UX Design"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "extend design",
           ok_result(%{starting_point: "extend_existing", library_hints: ["design"]})},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "extend_existing"})
      refute Map.has_key?(after_socket.assigns.active_flow.runner.intake, :library_id)
      # no flash about the ambiguity — silent drop, user picks in the flow
      assert after_socket.assigns.flash == %{}
    end

    test "unresolvable hint (no match) is dropped silently" do
      org = create_org()

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "extend nothing",
           ok_result(%{
             starting_point: "extend_existing",
             library_hints: ["Nonexistent Framework"]
           })},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "extend_existing"})
      refute Map.has_key?(after_socket.assigns.active_flow.runner.intake, :library_id)
    end

    test "empty library_hints never queries the DB" do
      socket = build_socket(%{current_organization: org()})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "anything",
           ok_result(%{starting_point: "scratch", library_hints: []})},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "scratch"})
      refute Map.has_key?(after_socket.assigns.active_flow.runner.intake, :library_id)
    end

    test "two unique hints resolve to library_id_a + library_id_b for merge" do
      org = create_org()
      {:ok, lib_a} = Library.create_library(org.id, %{name: "SFIA Framework v8"})
      {:ok, lib_b} = Library.create_library(org.id, %{name: "DAMA Body of Knowledge"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "merge our SFIA and DAMA frameworks",
           ok_result(%{starting_point: "merge", library_hints: ["SFIA", "DAMA"]})},
          socket
        )

      assert_create_flow_started(after_socket, %{
        starting_point: "merge",
        library_id_a: lib_a.id,
        library_id_b: lib_b.id
      })

      refute Map.has_key?(after_socket.assigns.active_flow.runner.intake, :library_id)
    end

    test "merge with one resolvable + one unresolvable hint drops both" do
      org = create_org()
      {:ok, _lib} = Library.create_library(org.id, %{name: "SFIA Framework"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "merge SFIA and Nope",
           ok_result(%{starting_point: "merge", library_hints: ["SFIA", "Nonexistent"]})},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "merge"})
      intake = after_socket.assigns.active_flow.runner.intake
      # Only one resolved -> falls back to single library_id; the picker will
      # still require the user to choose both libraries.
      refute Map.has_key?(intake, :library_id_a)
      refute Map.has_key?(intake, :library_id_b)
      assert intake[:library_id]
    end

    test "merge with two ambiguous hints emits no library ids" do
      org = create_org()
      {:ok, _} = Library.create_library(org.id, %{name: "Design System"})
      {:ok, _} = Library.create_library(org.id, %{name: "UX Design"})
      {:ok, _} = Library.create_library(org.id, %{name: "Backend Skills"})
      {:ok, _} = Library.create_library(org.id, %{name: "Backend Engineering"})

      socket = build_socket(%{current_organization: org})

      {:noreply, after_socket} =
        RhoWeb.AppLive.handle_info(
          {:smart_entry_result, "merge design and backend",
           ok_result(%{starting_point: "merge", library_hints: ["design", "backend"]})},
          socket
        )

      assert_create_flow_started(after_socket, %{starting_point: "merge"})
      intake = after_socket.assigns.active_flow.runner.intake
      refute Map.has_key?(intake, :library_id)
      refute Map.has_key?(intake, :library_id_a)
      refute Map.has_key?(intake, :library_id_b)
    end
  end
end
