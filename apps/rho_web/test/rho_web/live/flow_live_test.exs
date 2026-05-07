defmodule RhoWeb.FlowLiveTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Accounts.Organization
  alias RhoFrameworks.{FlowRunner, Repo}
  alias RhoFrameworks.Flows.CreateFramework

  setup do
    org_id = Ecto.UUID.generate()
    slug = "flow-test-#{System.unique_integer([:positive])}"
    Repo.insert!(%Organization{id: org_id, name: "Flow Test Org", slug: slug})

    org = %{id: org_id, slug: slug, name: "Flow Test Org"}
    user = %{id: Ecto.UUID.generate(), email: "flow@test.com"}

    %{org_id: org_id, org: org, user: user}
  end

  defp build_socket(assigns_override) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{}
        },
        assigns_override
      )

    struct!(Phoenix.LiveView.Socket, assigns: assigns)
  end

  defp put_connected(socket) do
    %{socket | transport_pid: self()}
  end

  describe "mount/3" do
    test "mounts with valid flow_id (connected)", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)

      assert socket.assigns.flow_module == CreateFramework
      assert length(socket.assigns.flow_steps) == 21
      assert socket.assigns.runner.node_id == :choose_starting_point
      assert socket.assigns.runner.intake == %{}
      assert socket.assigns.completed_steps == []
      assert socket.assigns.step_status == :idle
      assert is_binary(socket.assigns.session_id)
      assert socket.assigns.scope.session_id == socket.assigns.session_id

      DataTable.stop(socket.assigns.session_id)
    end

    test "mounts with valid flow_id (disconnected)", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)

      assert socket.assigns.flow_module == CreateFramework
      assert socket.assigns.session_id == nil
      assert socket.assigns.scope == nil
    end

    test "redirects on unknown flow_id", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "nonexistent"}, %{}, socket)

      assert socket.redirected
    end
  end

  describe "handle_event submit_form" do
    test "choose_starting_point submit advances to per-path intake then to next step", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      # Step 1: choose_starting_point → branches into per-path intake.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "from_template"},
          socket
        )

      assert socket.assigns.runner.intake[:starting_point] == "from_template"
      assert socket.assigns.runner.node_id == :intake_template
      assert :choose_starting_point in socket.assigns.completed_steps

      # Step 2: per-path intake (intake_template) captures name/description.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_template",
            "name" => "Test Framework",
            "description" => "A test description"
          },
          socket
        )

      assert socket.assigns.runner.intake[:name] == "Test Framework"
      assert socket.assigns.runner.intake[:description] == "A test description"
      assert :intake_template in socket.assigns.completed_steps

      DataTable.stop(sid)
    end

    test "choose_starting_point=from_template + populated domain lands at :similar_roles", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      # Step 1: choose_starting_point=from_template → :intake_template.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "from_template"},
          socket
        )

      # Step 2: :intake_template captures name/description, then auto-runs
      # :similar_roles via LoadSimilarRoles. With an empty test org it
      # returns no matches and the runner bounces back to :choose_starting_point.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_template",
            "name" => "Test Framework",
            "description" => "A test description"
          },
          socket
        )

      assert socket.assigns.runner.intake[:starting_point] == "from_template"
      assert socket.assigns.runner.node_id == :choose_starting_point
      assert :similar_roles in socket.assigns.completed_steps

      DataTable.stop(sid)
    end

    test "with no domain/target_roles + starting_point=scratch routes through :research", %{
      org: org,
      user: user
    } do
      # Stub ResearchDomain spawn so we don't make an LLM call.
      parent = self()

      spawn_fn = fn opts ->
        send(parent, {:research_spawn_called, opts})
        {:ok, "fixture-research-#{System.unique_integer([:positive])}"}
      end

      Application.put_env(:rho_frameworks, :research_domain_spawn_fn, spawn_fn)
      on_exit(fn -> Application.delete_env(:rho_frameworks, :research_domain_spawn_fn) end)

      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      # Step 1: choose_starting_point=scratch → :intake_scratch.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "scratch"},
          socket
        )

      assert socket.assigns.runner.node_id == :intake_scratch

      # Step 2: :intake_scratch submit → :research auto-runs.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_scratch",
            "name" => "Mystery Framework",
            "description" => "About something unfamiliar"
          },
          socket
        )

      assert socket.assigns.runner.node_id == :research
      assert :choose_starting_point in socket.assigns.completed_steps
      assert :intake_scratch in socket.assigns.completed_steps
      assert socket.assigns.research_agent_id != nil
      assert socket.assigns.step_status == :running
      assert_received {:research_spawn_called, _opts}

      DataTable.stop(sid)
    end

    test "research_continue advances regardless of worker state", %{
      org: org,
      user: user
    } do
      Application.put_env(:rho_frameworks, :research_domain_spawn_fn, fn _opts ->
        {:ok, "fixture-research-stuck"}
      end)

      on_exit(fn -> Application.delete_env(:rho_frameworks, :research_domain_spawn_fn) end)

      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake",
            "name" => "Mystery Framework",
            "description" => "About something unfamiliar"
          },
          socket
        )

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "scratch"},
          socket
        )

      assert socket.assigns.runner.node_id == :research

      # User clicks "Continue early" before the worker reports completion.
      {:noreply, socket} = RhoWeb.FlowLive.handle_event("research_continue", %{}, socket)

      # Flow has advanced past :research without waiting for task_completed.
      assert socket.assigns.runner.node_id == :generate
      assert :research in socket.assigns.completed_steps
      assert socket.assigns.research_agent_id == nil

      summary = socket.assigns.runner.summaries[:research]
      assert is_map(summary)
      assert summary.table_name == "research_notes"

      DataTable.stop(sid)
    end

    test "task_completed for research worker leaves the wizard waiting for user input", %{
      org: org,
      user: user
    } do
      Application.put_env(:rho_frameworks, :research_domain_spawn_fn, fn _opts ->
        {:ok, "fixture-research-natural"}
      end)

      on_exit(fn -> Application.delete_env(:rho_frameworks, :research_domain_spawn_fn) end)

      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "intake", "name" => "Mystery", "description" => "About"},
          socket
        )

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "scratch"},
          socket
        )

      assert socket.assigns.runner.node_id == :research
      assert socket.assigns.step_status == :running
      research_id = socket.assigns.research_agent_id

      # Worker finishes naturally — the runner should NOT auto-advance.
      task_completed =
        Rho.Events.event(:task_completed, sid, research_id, %{
          worker_agent_id: research_id,
          status: :ok
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_info(task_completed, socket)

      assert socket.assigns.runner.node_id == :research
      assert socket.assigns.step_status == :awaiting_user
      assert socket.assigns.research_agent_id == nil

      # User clicks Continue → flow advances.
      {:noreply, socket} = RhoWeb.FlowLive.handle_event("research_continue", %{}, socket)
      assert socket.assigns.runner.node_id == :generate
      assert :research in socket.assigns.completed_steps

      DataTable.stop(sid)
    end

    test "extend_existing with no libraries bounces back to :choose_starting_point", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      # Step 1: choose_starting_point=extend_existing → :intake_extend.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "extend_existing"},
          socket
        )

      # Step 2: :intake_extend → :pick_existing_library auto-runs
      # ListExistingLibraries; with an empty org it returns no matches and
      # the runner bounces back to :choose_starting_point.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_extend",
            "name" => "Backend PM Framework",
            "description" => "PMs working backend"
          },
          socket
        )

      assert socket.assigns.runner.intake[:starting_point] == "extend_existing"
      assert socket.assigns.runner.node_id == :choose_starting_point
      assert :pick_existing_library in socket.assigns.completed_steps

      DataTable.stop(sid)
    end

    test "extend_existing with existing libraries lands at :pick_existing_library", %{
      org_id: org_id,
      org: org,
      user: user
    } do
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Existing Backend Eng",
          description: "Pre-existing"
        })

      {:ok, _} =
        RhoFrameworks.Library.upsert_skill(lib.id, %{
          name: "API Design",
          category: "Eng",
          cluster: "Backend"
        })

      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      # Step 1: choose_starting_point=extend_existing → :intake_extend.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "extend_existing"},
          socket
        )

      # Step 2: :intake_extend → :pick_existing_library; org has a lib so
      # the picker stays put and waits for user selection.
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_extend",
            "name" => "Backend PM Framework",
            "description" => "PMs working backend"
          },
          socket
        )

      assert socket.assigns.runner.node_id == :pick_existing_library
      assert socket.assigns.step_status == :idle

      ids = Enum.map(socket.assigns.select_items, & &1.id)
      assert lib.id in ids

      DataTable.stop(sid)
    end
  end

  describe "handle_event continue" do
    test "advances to next step", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      runner =
        FlowRunner.init(CreateFramework,
          start: :review,
          intake: %{name: "Test", description: "Test"},
          summaries: %{generate: %{table_name: "library:Test", library_id: "lib-1"}}
        )

      socket =
        Phoenix.Component.assign(socket, %{
          runner: runner,
          completed_steps: [:intake, :generate],
          step_status: :idle
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_event("continue", %{}, socket)

      assert socket.assigns.runner.node_id == :confirm
      assert :review in socket.assigns.completed_steps

      # Regression: rendering an :action step that omits :use_case (here
      # the :confirm manual node) must not raise. Force evaluation of the
      # Rendered struct via Phoenix.HTML.Safe.to_iodata.
      assert socket.assigns
             |> RhoWeb.FlowLive.render()
             |> Phoenix.HTML.Safe.to_iodata()
             |> IO.iodata_to_binary()
             |> is_binary()

      DataTable.stop(sid)
    end
  end

  describe "policy_for_mode/1" do
    test ":guided uses Deterministic; copilot/open use Hybrid" do
      assert RhoWeb.FlowLive.policy_for_mode(:guided) ==
               RhoFrameworks.Flow.Policies.Deterministic

      assert RhoWeb.FlowLive.policy_for_mode(:copilot) ==
               RhoFrameworks.Flow.Policies.Hybrid

      assert RhoWeb.FlowLive.policy_for_mode(:open) ==
               RhoFrameworks.Flow.Policies.Hybrid
    end
  end

  describe "show_theater?/2" do
    test "guided always hides theater" do
      refute RhoWeb.FlowLive.show_theater?(:guided, %{routing: :auto})
      refute RhoWeb.FlowLive.show_theater?(:guided, %{routing: :agent_loop})
      refute RhoWeb.FlowLive.show_theater?(:guided, %{routing: :fixed})
    end

    test "open always shows theater" do
      assert RhoWeb.FlowLive.show_theater?(:open, %{routing: :auto})
      assert RhoWeb.FlowLive.show_theater?(:open, %{routing: :fixed})
    end

    test "copilot only shows theater on agent-driven nodes" do
      assert RhoWeb.FlowLive.show_theater?(:copilot, %{routing: :auto})
      assert RhoWeb.FlowLive.show_theater?(:copilot, %{routing: :agent_loop})
      refute RhoWeb.FlowLive.show_theater?(:copilot, %{routing: :fixed})
    end
  end

  describe "handle_event override_edge" do
    test "writes user_override and re-runs choose_next via the Hybrid short-circuit",
         %{org: org, user: user} do
      # No router stub needed: user_override short-circuits Hybrid before it
      # reaches the BAML router (§2.4).
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "copilot"},
          %{},
          socket
        )

      sid = socket.assigns.session_id

      # Simulate that the auto router routed choose_starting_point →
      # intake_extend (because intake.starting_point="extend_existing"
      # satisfies :extend_existing_intent), and we're now sitting at
      # :intake_extend with the chip showing the decision. The user
      # overrides to :intake_scratch — a valid edge via the nil fallback
      # since domain/target_roles are blank (:scratch guard fires too).
      runner =
        FlowRunner.init(CreateFramework,
          start: :intake_extend,
          intake: %{starting_point: "extend_existing"}
        )

      [csp_step] =
        Enum.filter(CreateFramework.steps(), fn s -> s.id == :choose_starting_point end)

      decision = %{
        node_id: :choose_starting_point,
        target: :intake_extend,
        reason: "router picked intake_extend",
        confidence: 0.9,
        allowed: csp_step.next
      }

      socket =
        Phoenix.Component.assign(socket, %{
          runner: runner,
          last_decision: decision,
          completed_steps: [:choose_starting_point],
          step_status: :idle,
          chip_expanded?: true
        })

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "override_edge",
          %{"node" => "choose_starting_point", "edge" => "intake_scratch"},
          socket
        )

      # The override is recorded on the runner. Hybrid honored it during
      # the re-advance (the runner walked back to :choose_starting_point,
      # then forward via the user-chosen edge).
      assert socket.assigns.runner.user_override[:choose_starting_point] == :intake_scratch
      assert socket.assigns.runner.node_id != :intake_extend
      assert socket.assigns.chip_expanded? == false

      DataTable.stop(sid)
    end

    test "ignores override on stale chip", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} =
        RhoWeb.FlowLive.mount(
          %{"flow_id" => "create-framework", "mode" => "copilot"},
          %{},
          socket
        )

      sid = socket.assigns.session_id

      # Runner is past the auto destination — chip would not render, but
      # if a stale event arrives, the handler must no-op.
      runner =
        FlowRunner.init(CreateFramework,
          start: :generate,
          intake: %{name: "X", description: "Y"}
        )

      [csp_step] =
        Enum.filter(CreateFramework.steps(), fn s -> s.id == :choose_starting_point end)

      stale_decision = %{
        node_id: :choose_starting_point,
        target: :research,
        reason: nil,
        confidence: 0.9,
        allowed: csp_step.next
      }

      socket =
        Phoenix.Component.assign(socket, %{
          runner: runner,
          last_decision: stale_decision,
          step_status: :idle
        })

      {:noreply, after_socket} =
        RhoWeb.FlowLive.handle_event(
          "override_edge",
          %{"node" => "choose_starting_point", "edge" => "similar_roles"},
          socket
        )

      assert after_socket.assigns.runner.node_id == :generate
      assert after_socket.assigns.runner.user_override == %{}

      DataTable.stop(sid)
    end
  end

  describe "handle_event set_mode" do
    test "updates mode assign", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      assert socket.assigns.mode == :guided

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event("set_mode", %{"mode" => "copilot"}, socket)

      assert socket.assigns.mode == :copilot

      DataTable.stop(sid)
    end

    test "invalid mode strings fall back to :guided", %{org: org, user: user} do
      socket =
        build_socket(%{
          current_organization: org,
          current_user: user
        })
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event("set_mode", %{"mode" => "bogus"}, socket)

      assert socket.assigns.mode == :guided

      DataTable.stop(sid)
    end
  end

  describe "intake prefill from query params" do
    test "seeds runner.intake with whitelisted fields", %{org: org, user: user} do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{
        "flow_id" => "create-framework",
        "name" => "Backend Engineering",
        "description" => "Skills for backend engineers",
        "domain" => "Software",
        "target_roles" => "Backend Engineer, Tech Lead",
        # Empty strings are dropped — caller passed nothing useful.
        "skill_count" => "",
        # Unknown keys are ignored, not blindly merged.
        "evil" => "atom-bomb"
      }

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      assert socket.assigns.runner.intake == %{
               name: "Backend Engineering",
               description: "Skills for backend engineers",
               domain: "Software",
               target_roles: "Backend Engineer, Tech Lead"
             }

      # The form_step component reads field values from `@form`, so the
      # intake must be mirrored there for prefill to actually render.
      assert socket.assigns.form == socket.assigns.runner.intake

      DataTable.stop(sid)
    end

    test "no params leaves intake empty", %{org: org, user: user} do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      assert socket.assigns.runner.intake == %{}

      DataTable.stop(sid)
    end

    test "starting_point and library_id pass the whitelist (Phase 10d)", %{
      org: org,
      user: user
    } do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{
        "flow_id" => "create-framework",
        "name" => "My Extended Framework",
        "starting_point" => "extend_existing",
        "library_id" => "lib-abc-123"
      }

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      assert socket.assigns.runner.intake[:starting_point] == "extend_existing"
      assert socket.assigns.runner.intake[:library_id] == "lib-abc-123"
      # mirrored to form so the :select default reads the right value
      assert socket.assigns.form[:starting_point] == "extend_existing"

      DataTable.stop(sid)
    end
  end

  describe ":pick_existing_library pre-pick from intake (Phase 10d)" do
    test "selected_ids is seeded when intake.library_id matches a loaded row", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Existing Frame",
          description: "for pre-pick test"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{
        "flow_id" => "create-framework",
        "name" => "Extending",
        "starting_point" => "extend_existing",
        "library_id" => lib.id
      }

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      # walk: choose_starting_point → intake_extend → pick_existing_library
      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "extend_existing"},
          socket
        )

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_extend",
            "name" => "Extending",
            "description" => "test"
          },
          socket
        )

      assert socket.assigns.runner.node_id == :pick_existing_library
      assert socket.assigns.selected_ids == [lib.id]

      DataTable.stop(sid)
    end

    test "selected_ids stays empty when intake.library_id doesn't match any row", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, _lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Different Lib",
          description: "won't match"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{
        "flow_id" => "create-framework",
        "name" => "Extending",
        "starting_point" => "extend_existing",
        "library_id" => "nonexistent-id"
      }

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "extend_existing"},
          socket
        )

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_extend",
            "name" => "Extending",
            "description" => "test"
          },
          socket
        )

      assert socket.assigns.runner.node_id == :pick_existing_library
      assert socket.assigns.selected_ids == []

      DataTable.stop(sid)
    end
  end

  describe ":pick_two_libraries pre-pick from intake (Phase 10e)" do
    test "selected_ids is seeded with both ids when both match loaded rows", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, lib_a} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "SFIA Framework",
          description: "for merge pre-pick test"
        })

      {:ok, lib_b} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "DAMA Body of Knowledge",
          description: "for merge pre-pick test"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{
        "flow_id" => "create-framework",
        "name" => "Merging",
        "starting_point" => "merge",
        "library_id_a" => lib_a.id,
        "library_id_b" => lib_b.id
      }

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "merge"},
          socket
        )

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_merge",
            "name" => "Merging",
            "description" => "test"
          },
          socket
        )

      assert socket.assigns.runner.node_id == :pick_two_libraries
      assert Enum.sort(socket.assigns.selected_ids) == Enum.sort([lib_a.id, lib_b.id])

      DataTable.stop(sid)
    end

    test "selected_ids stays empty when only one of two ids matches", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, lib_a} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "SFIA Framework",
          description: "exists"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{
        "flow_id" => "create-framework",
        "name" => "Merging",
        "starting_point" => "merge",
        "library_id_a" => lib_a.id,
        "library_id_b" => "nonexistent-id"
      }

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{"step_id" => "choose_starting_point", "starting_point" => "merge"},
          socket
        )

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "submit_form",
          %{
            "step_id" => "intake_merge",
            "name" => "Merging",
            "description" => "test"
          },
          socket
        )

      assert socket.assigns.runner.node_id == :pick_two_libraries
      assert socket.assigns.selected_ids == []

      DataTable.stop(sid)
    end
  end

  describe "edit-framework picker auto-advance" do
    test "auto-advances past :pick_existing_library when intake.library_id matches", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Editable Lib",
          description: "for edit-framework auto-advance test"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{"flow_id" => "edit-framework", "library_id" => lib.id}

      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      # Mount lands at :pick_existing_library which `maybe_auto_run`s into
      # `load_select_options`. With the singleton pre-pick + edit-framework,
      # the picker auto-advances and `maybe_auto_run` then runs the next
      # action step (`:load_existing_library`). Action steps don't auto-advance
      # after success — the user clicks Continue to move to :review. So the
      # post-mount snapshot lands at :load_existing_library / :completed.
      assert socket.assigns.runner.node_id == :load_existing_library
      assert socket.assigns.step_status == :completed
      assert :pick_existing_library in socket.assigns.completed_steps

      # User clicks Continue → advances to :review (FinalizeSkeleton head).
      {:noreply, socket} = RhoWeb.FlowLive.handle_event("continue", %{}, socket)
      assert socket.assigns.runner.node_id == :review

      DataTable.stop(sid)
    end

    test "stays at :pick_existing_library when intake.library_id is missing", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, _lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Editable Lib",
          description: "for fall-through test"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      # No library_id → no pre-pick → no auto-advance.
      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "edit-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      assert socket.assigns.runner.node_id == :pick_existing_library
      assert socket.assigns.selected_ids == []

      DataTable.stop(sid)
    end

    test "stays at :pick_existing_library when library_id doesn't match a loaded row", %{
      org: org,
      org_id: org_id,
      user: user
    } do
      {:ok, _lib} =
        RhoFrameworks.Library.create_library(org_id, %{
          name: "Different Lib",
          description: "won't match"
        })

      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      params = %{"flow_id" => "edit-framework", "library_id" => "nonexistent-id"}
      {:ok, socket} = RhoWeb.FlowLive.mount(params, %{}, socket)
      sid = socket.assigns.session_id

      # library_id is in intake but no match → empty pre-pick → no auto-advance.
      assert socket.assigns.runner.node_id == :pick_existing_library
      assert socket.assigns.selected_ids == []

      DataTable.stop(sid)
    end
  end

  describe "step_chat" do
    setup do
      parent = self()

      spawn_fn = fn opts ->
        agent_id = "fixture-step-chat-#{System.unique_integer([:positive])}"
        send(parent, {:step_chat_spawn_called, agent_id, opts})
        {:ok, agent_id}
      end

      Application.put_env(:rho_web, :step_chat_spawn_fn, spawn_fn)
      on_exit(fn -> Application.delete_env(:rho_web, :step_chat_spawn_fn) end)
      :ok
    end

    # Position the wizard at :save (use_case: SaveFramework, routing: :fixed,
    # not a fan_out — step_chat renders and is enabled).
    defp seed_step_chat_socket(org, user) do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)

      runner =
        FlowRunner.init(CreateFramework,
          start: :save,
          intake: %{
            name: "Backend Engineering",
            description: "Skills for backend engineers",
            domain: "Software",
            target_roles: "Backend Engineer",
            skill_count: "12",
            levels: "5"
          },
          summaries: %{
            generate: %{table_name: "library:Backend Engineering", library_id: "lib-1"}
          }
        )

      {socket
       |> Phoenix.Component.assign(%{
         runner: runner,
         completed_steps: [:intake, :similar_roles, :generate, :review, :confirm, :proficiency],
         step_status: :idle
       }), socket.assigns.session_id}
    end

    test "submit spawns the step-chat agent with the right tools and clears stream state",
         %{org: org, user: user} do
      {socket, sid} = seed_step_chat_socket(org, user)

      # Pre-existing residue from an earlier turn — must be cleared on submit.
      socket =
        Phoenix.Component.assign(socket, %{
          streaming_text: "stale",
          tool_events: [%{phase: :start, name: "old", status: nil, output: nil}],
          step_chat_pending_question: "old question"
        })

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "step_chat_submit",
          %{"message" => "use 8 skills not 12"},
          socket
        )

      assert is_binary(socket.assigns.step_chat_agent_id)
      assert socket.assigns.streaming_text == ""
      assert socket.assigns.tool_events == []
      assert socket.assigns.step_chat_pending_question == nil

      assert_received {:step_chat_spawn_called, agent_id, opts}
      assert agent_id == socket.assigns.step_chat_agent_id
      assert opts[:task] == "use 8 skills not 12"
      assert opts[:agent_name] == :step_chat
      assert opts[:session_id] == sid

      tool_names = opts[:tools] |> Enum.map(& &1.tool.name) |> Enum.sort()
      assert tool_names == ["clarify", "save_framework"]

      # System prompt embeds the wizard's intake + table name so the
      # chat agent doesn't have to clarify what framework it's on.
      sys = opts[:system_prompt]
      assert sys =~ "Backend Engineering"
      assert sys =~ "Skills for backend engineers"
      assert sys =~ "library:Backend Engineering"
      assert sys =~ "Skill count: 12"
      assert sys =~ "Proficiency levels: 5"

      DataTable.stop(sid)
    end

    test "ignores empty messages", %{org: org, user: user} do
      {socket, sid} = seed_step_chat_socket(org, user)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event("step_chat_submit", %{"message" => ""}, socket)

      assert socket.assigns.step_chat_agent_id == nil
      refute_received {:step_chat_spawn_called, _, _}

      DataTable.stop(sid)
    end

    test "tool_start / tool_result events are recorded while the agent runs",
         %{org: org, user: user} do
      {socket, sid} = seed_step_chat_socket(org, user)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "step_chat_submit",
          %{"message" => "save now"},
          socket
        )

      agent_id = socket.assigns.step_chat_agent_id

      tool_start =
        Rho.Events.event(:tool_start, sid, agent_id, %{
          name: "save_framework",
          args: %{},
          call_id: "c1",
          turn_id: "t1"
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_info(tool_start, socket)
      assert [%{phase: :start, name: "save_framework"}] = socket.assigns.tool_events

      tool_result =
        Rho.Events.event(:tool_result, sid, agent_id, %{
          name: "save_framework",
          output: "Saved 12 skills",
          status: :ok,
          call_id: "c1",
          effects: [],
          turn_id: "t1"
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_info(tool_result, socket)

      assert [_, %{phase: :result, name: "save_framework", status: :ok}] =
               socket.assigns.tool_events

      DataTable.stop(sid)
    end

    test "task_completed for the step_chat agent clears agent_id",
         %{org: org, user: user} do
      {socket, sid} = seed_step_chat_socket(org, user)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "step_chat_submit",
          %{"message" => "save"},
          socket
        )

      agent_id = socket.assigns.step_chat_agent_id

      task_completed =
        Rho.Events.event(:task_completed, sid, agent_id, %{
          worker_agent_id: agent_id,
          status: :ok,
          result: "ok"
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_info(task_completed, socket)

      assert socket.assigns.step_chat_agent_id == nil

      DataTable.stop(sid)
    end

    test ":step_chat_clarify event sets the pending question",
         %{org: org, user: user} do
      {socket, sid} = seed_step_chat_socket(org, user)

      {:noreply, socket} =
        RhoWeb.FlowLive.handle_event(
          "step_chat_submit",
          %{"message" => "save"},
          socket
        )

      agent_id = socket.assigns.step_chat_agent_id

      clarify =
        Rho.Events.event(:step_chat_clarify, sid, agent_id, %{
          question: "Save to which library?",
          agent_id: agent_id
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_info(clarify, socket)

      assert socket.assigns.step_chat_pending_question == "Save to which library?"

      # An event for a stale agent_id is ignored.
      stale =
        Rho.Events.event(:step_chat_clarify, sid, "other-agent", %{
          question: "stale",
          agent_id: "other-agent"
        })

      {:noreply, socket} = RhoWeb.FlowLive.handle_info(stale, socket)
      assert socket.assigns.step_chat_pending_question == "Save to which library?"

      DataTable.stop(sid)
    end

    test "disabled? prevents submission during fan_out :running", %{org: org, user: user} do
      socket =
        build_socket(%{current_organization: org, current_user: user})
        |> put_connected()

      {:ok, socket} = RhoWeb.FlowLive.mount(%{"flow_id" => "create-framework"}, %{}, socket)
      sid = socket.assigns.session_id

      runner =
        FlowRunner.init(CreateFramework,
          start: :proficiency,
          intake: %{name: "Stub", description: "Stub", levels: "5"},
          summaries: %{generate: %{table_name: "library:Stub", library_id: "lib-1"}}
        )

      socket =
        Phoenix.Component.assign(socket, %{
          runner: runner,
          step_status: :running,
          workers: [%{agent_id: "w1", category: "Eng", count: 3, status: :running}]
        })

      {:noreply, after_socket} =
        RhoWeb.FlowLive.handle_event(
          "step_chat_submit",
          %{"message" => "regenerate"},
          socket
        )

      assert after_socket.assigns.step_chat_agent_id == nil
      refute_received {:step_chat_spawn_called, _, _}

      DataTable.stop(sid)
    end
  end
end
