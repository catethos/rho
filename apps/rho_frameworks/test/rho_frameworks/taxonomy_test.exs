defmodule RhoFrameworks.TaxonomyTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Taxonomy

  test "parses plain-language preferences into internal defaults" do
    prefs =
      Taxonomy.parse_preferences(%{
        "taxonomy_size" => "compact",
        "transferability" => "role_or_industry_specific",
        "specificity" => "industry_specific"
      })

    assert prefs.taxonomy_size == "compact"
    assert prefs.transferability == "role_specific"
    assert prefs.specificity == "industry_specific"
    assert prefs.category_count == 3
    assert prefs.clusters_per_category == "2"
    assert prefs.skills_per_cluster == "2-3"
  end

  test "flattens taxonomy result into stable category/cluster rows" do
    rows =
      Taxonomy.rows_from_result(
        %{
          categories: [
            %{
              name: "Technical Foundation",
              description: "Core technical work.",
              rationale: "Required base.",
              clusters: [
                %{
                  name: "Architecture",
                  description: "Designing systems.",
                  rationale: "Architecture decisions.",
                  target_skill_count: 3,
                  transferability: "transferable"
                }
              ]
            }
          ]
        },
        Taxonomy.parse_preferences(%{})
      )

    assert [
             %{
               id: "tax_technical_foundation__architecture",
               category: "Technical Foundation",
               cluster: "Architecture",
               target_skill_count: 3,
               transferability: "transferable"
             }
           ] = rows
  end

  test "allowed_skill? checks category and cluster against approved taxonomy" do
    rows = [
      %{category: "Technical Foundation", cluster: "Architecture"},
      %{category: "Delivery", cluster: "Execution"}
    ]

    allowed = Taxonomy.allowed_pairs(rows)

    assert Taxonomy.allowed_skill?(
             %{category: "technical foundation", cluster: "architecture"},
             allowed
           )

    refute Taxonomy.allowed_skill?(%{category: "Delivery", cluster: "Architecture"}, allowed)
  end
end
