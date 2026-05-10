defmodule Rho.PathsTest do
  use ExUnit.Case, async: false

  describe "data_dir/0" do
    test "defaults to ~/.rho when env var unset" do
      System.delete_env("RHO_DATA_DIR")
      assert Rho.Paths.data_dir() == Path.expand("~/.rho")
    end

    test "honors RHO_DATA_DIR env var" do
      System.put_env("RHO_DATA_DIR", "/tmp/rho_test_data")
      on_exit(fn -> System.delete_env("RHO_DATA_DIR") end)
      assert Rho.Paths.data_dir() == "/tmp/rho_test_data"
    end

    test "treats empty env var as unset" do
      System.put_env("RHO_DATA_DIR", "")
      on_exit(fn -> System.delete_env("RHO_DATA_DIR") end)
      assert Rho.Paths.data_dir() == Path.expand("~/.rho")
    end
  end

  describe "user_workspace/2" do
    setup do
      System.put_env("RHO_DATA_DIR", "/tmp/rho_test")
      on_exit(fn -> System.delete_env("RHO_DATA_DIR") end)
      :ok
    end

    test "scopes by integer user_id" do
      assert Rho.Paths.user_workspace(42, "ses_abc") ==
               "/tmp/rho_test/users/u42/workspaces/ses_abc"
    end

    test "scopes by string user_id" do
      assert Rho.Paths.user_workspace("alice", "ses_abc") ==
               "/tmp/rho_test/users/ualice/workspaces/ses_abc"
    end

    test "falls back to _anon when user_id is nil" do
      assert Rho.Paths.user_workspace(nil, "ses_abc") ==
               "/tmp/rho_test/users/_anon/workspaces/ses_abc"
    end
  end

  test "tapes_dir and sandboxes_dir live under data_dir" do
    System.put_env("RHO_DATA_DIR", "/tmp/rho_test")
    on_exit(fn -> System.delete_env("RHO_DATA_DIR") end)
    assert Rho.Paths.tapes_dir() == "/tmp/rho_test/tapes"
    assert Rho.Paths.sandboxes_dir() == "/tmp/rho_test/sandboxes"
  end
end
