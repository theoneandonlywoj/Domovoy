defmodule Domovoy.Dashboard.Project do
  @moduledoc """
  One dashboard project: a name, a path and the stats its card shows.

  The stats and status are stored columns, set only by seeds; a new project starts
  idle with zero counts and 14 days of zero activity. The slug comes from the name,
  ASCII letters and digits only, and is unique; it is also the seeds' natural key.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Domovoy.Composer

  @type status :: :running | :healthy | :failing | :attention | :idle
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  @text_fields [:name, :description, :path]
  @stat_fields [:status, :repos, :worktrees, :jobs, :workflows, :activity]

  schema "dashboard_projects" do
    field :slug, :string
    field :name, :string
    field :description, :string, default: ""
    field :path, :string

    field :status, Ecto.Enum,
      values: [:running, :healthy, :failing, :attention, :idle],
      default: :idle

    field :repos, :integer, default: 0
    field :worktrees, :integer, default: 0
    field :jobs, :integer, default: 0
    field :workflows, :integer, default: 0
    field :activity, {:array, :integer}, default: List.duplicate(0, 14)

    timestamps()
  end

  @doc """
  Casts a name, a description and a path, refusing text Postgres can't store, and
  derives the slug from the name. A `nil` description falls back to `""`.
  """
  @spec changeset(project :: t(), attrs :: map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = project, attrs) do
    project
    |> cast(attrs, @text_fields, empty_values: [nil | Ecto.Changeset.empty_values()])
    |> validate_required([:name, :path])
    |> validate_text(@text_fields)
    |> put_slug()
    |> unique_constraint(:slug, error_key: :name, message: "has already been taken")
  end

  @doc """
  The seeds' changeset: `changeset/2`, then the stored stats and status as given.
  """
  @spec seed_changeset(project :: t(), attrs :: map()) :: Ecto.Changeset.t()
  def seed_changeset(%__MODULE__{} = project, attrs) do
    project
    |> changeset(attrs)
    |> change(Map.take(attrs, @stat_fields))
  end

  @doc false
  @spec validate_text(changeset :: Ecto.Changeset.t(), fields :: [atom()]) ::
          Ecto.Changeset.t()
  def validate_text(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      acc
      |> validate_length(field, max: 255, count: :codepoints)
      |> validate_change(field, &text_errors/2)
    end)
  end

  @spec text_errors(field :: atom(), value :: String.t()) :: keyword()
  defp text_errors(field, value),
    do: if(Composer.text_safe?(value), do: [], else: [{field, "must be text without NUL"}])

  # A name that already has an error gets no slug, so it never gets a second error.
  # Only a name that is valid text reaches the regex, which raises on broken UTF-8.
  # Downcasing can lengthen a name, so the slug is checked against the column too.
  @spec put_slug(changeset :: Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp put_slug(changeset) do
    with false <- Keyword.has_key?(changeset.errors, :name),
         name when is_binary(name) <- get_change(changeset, :name),
         true <- Composer.text_safe?(name) do
      slug =
        name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-") |> String.trim("-")

      cond do
        slug == "" -> add_error(changeset, :name, "must contain a letter or digit")
        String.length(slug) > 255 -> add_error(changeset, :name, "is too long")
        true -> put_change(changeset, :slug, slug)
      end
    else
      _skip -> changeset
    end
  end
end
