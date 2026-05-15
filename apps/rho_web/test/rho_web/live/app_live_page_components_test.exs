defmodule RhoWeb.AppLivePageComponentsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.PageComponents

  test "role_subtitle joins present role context in display order" do
    profile = %{
      role_family: "Engineering",
      seniority_label: "Senior",
      description: "Builds reliable systems"
    }

    assert PageComponents.role_subtitle(profile) ==
             "Engineering - Senior - Builds reliable systems"
  end

  test "role_subtitle returns nil when no context is present" do
    assert PageComponents.role_subtitle(%{
             role_family: nil,
             seniority_label: "",
             description: nil
           }) == nil
  end

  test "has_rich_fields? detects role detail sections" do
    refute PageComponents.has_rich_fields?(%{
             purpose: nil,
             accountabilities: "",
             success_metrics: nil,
             qualifications: nil,
             reporting_context: nil
           })

    assert PageComponents.has_rich_fields?(%{
             purpose: nil,
             accountabilities: "Own delivery",
             success_metrics: nil,
             qualifications: nil,
             reporting_context: nil
           })
  end
end
