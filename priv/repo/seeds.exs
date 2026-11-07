# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Domovoy.Repo.insert!(%Domovoy.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

for {name, outcome} <- Domovoy.Examples.Seeds.run() do
  IO.puts("Composer draft #{name}: #{outcome}")
end
