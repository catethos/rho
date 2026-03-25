defmodule Rho.Demos.Hiring.Candidates do
  @moduledoc """
  Synthetic candidate profiles for the hiring committee simulation.
  No demographic/protected fields — only job-relevant dimensions.
  """

  def all do
    [
      %{
        id: "C01", name: "Sarah Chen",
        years_experience: 8, current_company: "Stripe",
        education: "MS CS, Stanford",
        skills: ["Elixir", "Go", "distributed systems", "PostgreSQL"],
        salary_expectation: 195_000,
        strengths: "Led payment pipeline migration (10M+ txns/day). Phoenix core team contributor.",
        concerns: "3 jobs in 4 years. References note difficulty with ambiguity. Salary $5K over band ceiling.",
        work_style: "Remote, prefers async communication, strong writer",
        tension: "$5K over budget · 3 jobs in 4yr"
      },
      %{
        id: "C02", name: "Wei Zhang",
        years_experience: 12, current_company: "Google",
        education: "PhD CS, MIT",
        skills: ["Erlang", "Elixir", "distributed consensus", "C++", "Kubernetes"],
        salary_expectation: 185_000,
        strengths: "Built Spanner-adjacent replication layer. 200+ commits to OTP. Exceptional debugger.",
        concerns: "Code reviews described as 'brutal'. Two direct reports transferred teams. Solo contributor preference.",
        work_style: "Office-first, prefers synchronous pairing, terse communicator",
        tension: "\"Brutal\" reviews · 2 reports transferred"
      },
      %{
        id: "C03", name: "Marcus Johnson",
        years_experience: 6, current_company: "Thoughtbot",
        education: "Bootcamp (Turing School), BA English",
        skills: ["Elixir", "Ruby", "PostgreSQL", "LiveView", "TDD"],
        salary_expectation: 165_000,
        strengths: "Strong portfolio of shipped products. Excellent technical writing. Mentors junior devs weekly.",
        concerns: "No CS degree. Limited distributed systems experience. Hasn't worked at scale (>1M users).",
        work_style: "Remote, highly collaborative, active in open source community",
        tension: "No CS degree · limited scale experience"
      },
      %{
        id: "C04", name: "Aisha Patel",
        years_experience: 5, current_company: "Shopify",
        education: "BS CS, Waterloo",
        skills: ["Elixir", "LiveView", "GraphQL", "PostgreSQL"],
        salary_expectation: 172_000,
        strengths: "Led LiveView migration at Shopify. Built real-time inventory system. Strong async communicator.",
        concerns: "Only 5 years experience. No distributed consensus work. May need senior mentoring.",
        work_style: "Hybrid, strong async + sync",
        tension: "Best all-rounder? · Less senior"
      },
      %{
        id: "C05", name: "David Park",
        years_experience: 15, current_company: "Netflix",
        education: "MS CS, Berkeley",
        skills: ["Elixir", "Rust", "event systems", "Kubernetes"],
        salary_expectation: 210_000,
        strengths: "Built real-time event pipeline at Netflix. Architect-level system design. 15yr track record.",
        concerns: "$20K over budget ceiling. May be overqualified — risk of boredom. Prefers architect role, not hands-on coding.",
        work_style: "Office, mentors architects",
        tension: "$20K over budget · may be overqualified"
      }
    ]
  end

  def format_all do
    all()
    |> Enum.map_join("\n---\n", fn c ->
      """
      **#{c.id}: #{c.name}**
      Experience: #{c.years_experience} years | Current: #{c.current_company}
      Education: #{c.education}
      Skills: #{Enum.join(c.skills, ", ")}
      Salary expectation: $#{format_salary(c.salary_expectation)}
      Strengths: #{c.strengths}
      Concerns: #{c.concerns}
      Work style: #{c.work_style}
      """
    end)
  end

  defp format_salary(amount) do
    amount
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
