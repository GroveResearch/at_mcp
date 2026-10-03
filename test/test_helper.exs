# `:goal` marks the parts of AtMcp's purpose that are not built yet. They are
# written as real tests so that finishing one is something the suite says rather
# than something a person judges, and excluded here so an unbuilt goal does not
# block work on the others. Run them with `mix test --only goal`.
ExUnit.start(exclude: [:goal])
