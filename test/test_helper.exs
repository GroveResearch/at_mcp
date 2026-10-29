# `:goal` marks the parts of AtMcp's purpose that are not built yet. They are
# written as real tests so that finishing one is something the suite says rather
# than something a person judges, and excluded here so an unbuilt goal does not
# block work on the others. Run them with `mix test --only goal`.
#
# `:e2e` marks the round trips against a local reference network
# (test/e2e/), which needs Node, Postgres, Redis and a built atproto
# checkout. Run them with scripts/e2e.sh (CONTRIBUTING.md, "End-to-end
# round trips").
#
# `:hosts` marks reads run through a real host (test/at_mcp/hosts_test.exs),
# which calls a model and needs its credential. The `hosts` job in
# .github/workflows/check.yml runs them with `mix test --only hosts`.
ExUnit.start(exclude: [:goal, :e2e, :hosts])
