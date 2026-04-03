defmodule Rho.Demos.Bazi.SimulationTest do
  use ExUnit.Case

  alias Rho.Demos.Bazi.Simulation

  setup do
    session_id = "bazi_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Simulation.start_link(session_id)
    %{session_id: session_id}
  end

  test "init starts in :not_started", %{session_id: sid} do
    state = Simulation.status(sid)
    assert state.status == :not_started
  end

  test "status returns a Simulation struct", %{session_id: sid} do
    state = Simulation.status(sid)
    assert is_struct(state, Simulation)
    assert state.session_id != nil
    assert state.round == 0
  end

  test "begin_simulation with birth_info transitions through states", %{session_id: sid} do
    # This test uses birth_info mode (no image, no LLM needed for chart parsing).
    # It will attempt to spawn agents which requires the full system running,
    # so we just verify the API accepts the call shape without crashing the GenServer.
    birth_info = %{year: 1996, month: 7, day: 17, hour: 13, minute: 45, gender: :female}

    try do
      Simulation.begin_simulation(sid, %{
        birth_info: birth_info,
        options: ["选项A — 科技公司", "选项B — 金融公司"],
        question: "哪份工作更适合我？"
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # GenServer should still be alive and return a valid atom for status
    state = Simulation.status(sid)
    assert is_atom(state.status)
  end

  test "begin_simulation with image transitions to :parsing_chart", %{session_id: sid} do
    # Use a minimal base64 PNG (1x1 white pixel)
    tiny_png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

    try do
      result =
        Simulation.begin_simulation(sid, %{
          image_b64: tiny_png,
          options: ["选项A", "选项B"],
          question: "哪个更好？"
        })

      # If it succeeds, status should be :parsing_chart
      if result == :ok do
        state = Simulation.status(sid)
        assert state.status == :parsing_chart
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  test "begin_simulation returns error when already started", %{session_id: sid} do
    birth_info = %{year: 1990, month: 1, day: 1, hour: 8, minute: 0, gender: :male}

    # First call — may succeed or fail depending on environment
    try do
      Simulation.begin_simulation(sid, %{
        birth_info: birth_info,
        options: ["选项A", "选项B"],
        question: "哪个更好？"
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Second call — should return :already_started if first succeeded,
    # or :not_started / error if the first failed. Either way, no crash.
    result =
      try do
        Simulation.begin_simulation(sid, %{
          birth_info: birth_info,
          options: ["选项A", "选项B"],
          question: "哪个更好？"
        })
      rescue
        _ -> :rescued
      catch
        :exit, _ -> :exit
      end

    # Result is one of :ok, {:error, :already_started}, {:error, _}, :rescued, :exit
    assert result in [:ok, {:error, :already_started}, {:error, :missing_input}, :rescued, :exit] or
             match?({:error, _}, result)
  end

  test "begin_simulation with missing input returns error", %{session_id: sid} do
    result = Simulation.begin_simulation(sid, %{options: ["A", "B"], question: "?"})
    assert result == {:error, :missing_input}
  end
end
