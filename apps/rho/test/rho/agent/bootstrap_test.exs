defmodule Rho.Agent.BootstrapTest do
  use ExUnit.Case, async: true

  alias Rho.Agent.Bootstrap

  defmodule FakeTape do
    def memory_ref(session_id, workspace) do
      send(self(), {:memory_ref, session_id, workspace})
      "fake_tape:#{session_id}"
    end

    def bootstrap(tape_ref) do
      send(self(), {:bootstrap, tape_ref})
      :ok
    end
  end

  describe "prepare/1" do
    test "finalizes an explicit RunSpec against an existing tape ref" do
      run_spec =
        Rho.RunSpec.build(
          model: "mock:test",
          tape_module: FakeTape,
          conversation_id: "spec_conversation",
          thread_id: "spec_thread",
          user_id: "spec_user",
          organization_id: "spec_org"
        )

      seed =
        Bootstrap.prepare(
          agent_id: "ses_boot/primary",
          session_id: "ses_boot",
          workspace: "/tmp/rho_bootstrap",
          agent_name: :default,
          run_spec: run_spec,
          tape_ref: "existing_tape",
          capabilities: [:custom],
          user_id: "opt_user",
          organization_id: "opt_org",
          conversation_id: "opt_conversation",
          thread_id: "opt_thread"
        )

      refute_received {:memory_ref, _, _}
      refute_received {:bootstrap, _}

      assert seed.tape_ref == "existing_tape"
      assert seed.workspace == "/tmp/rho_bootstrap"
      assert seed.real_workspace == "/tmp/rho_bootstrap"
      assert seed.sandbox == nil
      assert seed.capabilities == [:custom]
      assert seed.user_id == "opt_user"
      assert seed.organization_id == "opt_org"
      assert seed.conversation_id == "opt_conversation"
      assert seed.thread_id == "opt_thread"

      assert seed.run_spec.agent_id == "ses_boot/primary"
      assert seed.run_spec.session_id == "ses_boot"
      assert seed.run_spec.workspace == "/tmp/rho_bootstrap"
      assert seed.run_spec.tape_name == "existing_tape"
      assert seed.run_spec.tape_module == FakeTape
      assert seed.run_spec.depth == 0
      assert seed.run_spec.user_id == "opt_user"
      assert seed.run_spec.organization_id == "opt_org"
      assert seed.run_spec.conversation_id == "opt_conversation"
      assert seed.run_spec.thread_id == "opt_thread"
    end

    test "bootstraps primary tape and builds registry metadata" do
      seed =
        Bootstrap.prepare(
          agent_id: "ses_primary/primary",
          session_id: "ses_primary",
          workspace: "/tmp/rho_primary",
          run_spec: Rho.RunSpec.build(model: "mock:bootstrap", tape_module: FakeTape)
        )

      assert_received {:memory_ref, "ses_primary", "/tmp/rho_primary"}
      assert_received {:bootstrap, "fake_tape:ses_primary"}

      assert seed.tape_ref == "fake_tape:ses_primary"
      assert seed.run_spec.tape_name == "fake_tape:ses_primary"
      assert seed.run_spec.workspace == "/tmp/rho_primary"

      registry_entry = Bootstrap.registry_entry(seed)
      assert registry_entry.session_id == "ses_primary"
      assert registry_entry.agent_name == :default
      assert registry_entry.status == :idle
      assert registry_entry.tape_ref == "fake_tape:ses_primary"

      started_data = Bootstrap.started_event_data(seed)
      assert started_data.model == "mock:bootstrap"
      assert started_data.role == :primary
      assert started_data.depth == 0
    end
  end
end
