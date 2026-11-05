defmodule Domovoy.Composer do
  @moduledoc """
  The composer's entry point: draft persistence, edits and undo, analysis and
  validation.

  Document reads and writes pass `log: false`, because a document's literals may
  hold secrets and the Repo logs query parameters at debug.
  """

  import Ecto.Query

  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Export
  alias Domovoy.Composer.History
  alias Domovoy.Composer.LiteralPolicy
  alias Domovoy.Composer.Operations
  alias Domovoy.Composer.Projection
  alias Domovoy.Repo

  @suffix_bytes 3
  @fallback_name "workflow"
  # The name limit of `DomovoyCore.Name`, less the suffix and its separator.
  @slug_limit 128 - 2 * @suffix_bytes - 1

  defdelegate edit(document, op), to: Operations
  defdelegate preview(document, op), to: Operations
  defdelegate push_history(history, document, kind), to: History, as: :push
  defdelegate undo(history), to: History
  defdelegate history_empty?(history), to: History, as: :empty?
  defdelegate reset_history(), to: History, as: :reset
  defdelegate issues(document), to: Analyzer
  defdelegate shape_issues(document), to: Document
  defdelegate text_safe?(term), to: Document
  defdelegate stage_view(document, stage), to: Projection
  defdelegate workflow_view(document), to: Projection
  defdelegate route_targets(document, source), to: Projection
  defdelegate connect_targets(document, stage, source), to: Projection
  defdelegate after_targets(document, stage, source), to: Projection
  defdelegate runners_reading(document, stage, source), to: Projection
  defdelegate consumers(document, node), to: Projection
  defdelegate issue_rows(document, issues, stage), to: Projection
  defdelegate literal_editor(type), to: LiteralPolicy, as: :editor
  defdelegate nodes(document, stage), to: Document

  @doc """
  Decides Definition valid, through `Domovoy.Composer.Export.validate/2`.
  """
  @spec validate(document :: Document.t()) :: Export.result()
  def validate(document) do
    Export.validate(
      document,
      Application.get_env(:domovoy, :composer_export_steps, Export.default_steps())
    )
  end

  @doc """
  Lists drafts, most recently saved first. Timestamps have whole seconds, so drafts
  saved in the same second sort by title, and only then by their random id.
  """
  @spec list_drafts() :: [Draft.t()]
  def list_drafts do
    query =
      from(draft in Draft, order_by: [desc: draft.updated_at, asc: draft.title, asc: draft.id])

    Repo.all(query, log: false)
  end

  @doc """
  Finds a draft. A malformed id is the same as an unknown one.
  """
  @spec get_draft(id :: term()) :: {:ok, Draft.t()} | {:error, :not_found}
  def get_draft(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Draft{} = draft <- Repo.get(Draft, uuid, log: false) do
      {:ok, draft}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Creates a draft with a starter stage. Its engine name comes from the title.
  """
  @spec create_draft(attrs :: map()) :: {:ok, Draft.t()} | {:error, Ecto.Changeset.t()}
  def create_draft(attrs) when is_map(attrs) do
    title = Map.get(attrs, :title, Map.get(attrs, "title"))

    %Draft{}
    |> Draft.changeset(%{title: title, document: Document.new(workflow_name(title))})
    |> Repo.insert(log: false)
  end

  @doc """
  Saves a document. A stale draft gives `:conflict` when its row still exists,
  leaving the newer save intact, and `:gone` when it was deleted.

  The write is forced, because Ecto skips an update with no changes and so skips
  the lock check too. A save of an unchanged document therefore bumps the lock.
  """
  @spec save_document(draft :: Draft.t(), document :: Document.t()) ::
          {:ok, Draft.t()} | {:error, :conflict | :gone | Ecto.Changeset.t()}
  def save_document(%Draft{} = draft, document), do: save(draft, %{document: document})

  @doc """
  Saves a title, under the same lock as `save_document/2`.
  """
  @spec save_title(draft :: Draft.t(), title :: String.t()) ::
          {:ok, Draft.t()} | {:error, :conflict | :gone | Ecto.Changeset.t()}
  def save_title(%Draft{} = draft, title), do: save(draft, %{title: title})

  @doc """
  Deletes a draft.
  """
  @spec delete_draft(draft :: Draft.t()) :: {:ok, Draft.t()} | {:error, :gone}
  def delete_draft(%Draft{} = draft) do
    case Repo.delete(draft, log: false, stale_error_field: :id) do
      {:ok, deleted} -> {:ok, deleted}
      {:error, _changeset} -> {:error, :gone}
    end
  end

  @spec save(draft :: Draft.t(), attrs :: map()) ::
          {:ok, Draft.t()} | {:error, :conflict | :gone | Ecto.Changeset.t()}
  defp save(draft, attrs) do
    draft
    |> Draft.changeset(attrs)
    |> Repo.update(log: false, stale_error_field: :lock_version, force: true)
    |> case do
      {:ok, saved} -> {:ok, saved}
      {:error, changeset} -> {:error, save_error(draft, changeset)}
    end
  end

  @spec save_error(draft :: Draft.t(), changeset :: Ecto.Changeset.t()) ::
          :conflict | :gone | Ecto.Changeset.t()
  defp save_error(draft, changeset) do
    cond do
      not Keyword.has_key?(changeset.errors, :lock_version) -> changeset
      Repo.exists?(from(row in Draft, where: row.id == ^draft.id), log: false) -> :conflict
      true -> :gone
    end
  end

  @spec workflow_name(title :: term()) :: String.t()
  defp workflow_name(title) do
    base =
      case slug(title) do
        "" -> @fallback_name
        slug -> slug
      end

    suffix = @suffix_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{base}_#{suffix}"
  end

  @spec slug(title :: term()) :: String.t()
  defp slug(title) when is_binary(title) do
    if String.valid?(title) do
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @slug_limit)
    else
      ""
    end
  end

  defp slug(_title), do: ""
end
