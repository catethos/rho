defmodule RhoWeb.AppLiveMessageEventsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.MessageEvents

  describe "create_framework_request?/2" do
    test "routes skill-library creation language into the framework flow" do
      assert MessageEvents.create_framework_request?(
               "create a skill library for risk analyst",
               []
             )

      assert MessageEvents.create_framework_request?(
               "build a skills library for risk analysts",
               []
             )
    end

    test "still routes explicit framework creation language" do
      assert MessageEvents.create_framework_request?(
               "create a framework for risk analysts",
               []
             )

      assert MessageEvents.create_framework_request?(
               "design a competency framework for finance roles",
               []
             )
    end

    test "does not capture ordinary skill lookup or image submissions" do
      refute MessageEvents.create_framework_request?("find a skill library", [])
      refute MessageEvents.create_framework_request?("create a skill library", [:image])
    end
  end

  describe "create_framework_intake/1" do
    test "derives a usable name and description from target-role language" do
      assert MessageEvents.create_framework_intake("create a skill framework for risk analyst") ==
               %{
                 name: "Risk Analyst",
                 description: "Skill framework for risk analyst.",
                 target_roles: "risk analyst"
               }
    end
  end
end
