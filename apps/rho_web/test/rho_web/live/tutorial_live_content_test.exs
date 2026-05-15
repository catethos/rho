defmodule RhoWeb.TutorialLiveContentTest do
  use ExUnit.Case, async: true

  alias RhoWeb.TutorialLive.Content

  test "sections expose the table of contents in page order" do
    assert hd(Content.sections()) == {"welcome", "Welcome"}
    assert List.last(Content.sections()) == {"next", "You're ready"}
    assert Enum.any?(Content.sections(), &(&1 == {"frameworks", "Create a skill framework"}))
  end

  test "style_tag wraps tutorial css as safe markup" do
    assert {:safe, ["<style>", css, "</style>"]} = Content.style_tag()
    assert css =~ ".tut-shell"
    assert css =~ "@media"
  end

  test "example_agent_config keeps the documented .rho.exs shape" do
    config = Content.example_agent_config()

    assert config =~ "my_helper:"
    assert config =~ "plugins: [:journal, :web_fetch]"
    assert config =~ "turn_strategy: :direct"
  end
end
