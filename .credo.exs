%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "mix.exs",
          "config/",
          "apps/",
          "priv/repo/migrations/"
        ],
        excluded: [
          "_build/",
          "deps/",
          "apps/rho/priv/baml_src/dynamic/"
        ]
      },
      plugins: [{ExSlop, []}]
    }
  ]
}
