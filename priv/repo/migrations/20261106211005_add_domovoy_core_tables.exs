defmodule Domovoy.Repo.Migrations.AddDomovoyCoreTables do
  use Ecto.Migration

  def up, do: DomovoyCore.Migrations.up(version: 3)

  # Version 1 undoes every version, so a rollback drops the tables.
  def down, do: DomovoyCore.Migrations.down(version: 1)
end
