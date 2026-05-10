defmodule Rho.SessionOwnersTest do
  # Touches the global ETS table — must be serial.
  use ExUnit.Case, async: false

  alias Rho.SessionOwners

  setup do
    # Isolate disk state per test run.
    tmp = Path.join(System.tmp_dir!(), "rho_owners_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("RHO_DATA_DIR", tmp)
    on_exit(fn ->
      System.delete_env("RHO_DATA_DIR")
      File.rm_rf!(tmp)
    end)
    :ok
  end

  test "authorize is a no-op for nil user_id (system context)" do
    assert :ok = SessionOwners.authorize("ses_sys_#{:rand.uniform(1_000_000)}", nil)
  end

  test "first authorize TOFU-registers the caller" do
    sid = "ses_tofu_#{:rand.uniform(1_000_000)}"
    assert :ok = SessionOwners.authorize(sid, 1)
    assert {:ok, "1"} = SessionOwners.owner(sid)
  end

  test "second user is forbidden after first claims" do
    sid = "ses_forbid_#{:rand.uniform(1_000_000)}"
    assert :ok = SessionOwners.authorize(sid, 1)
    assert {:error, :forbidden} = SessionOwners.authorize(sid, 2)
  end

  test "owner can re-authorize idempotently" do
    sid = "ses_idem_#{:rand.uniform(1_000_000)}"
    assert :ok = SessionOwners.authorize(sid, "alice")
    assert :ok = SessionOwners.authorize(sid, "alice")
  end

  test "integer and string forms of user_id are treated as the same identity" do
    sid = "ses_norm_#{:rand.uniform(1_000_000)}"
    assert :ok = SessionOwners.authorize(sid, 42)
    assert :ok = SessionOwners.authorize(sid, "42")
  end
end
