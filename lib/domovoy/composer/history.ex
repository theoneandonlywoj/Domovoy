defmodule Domovoy.Composer.History do
  @moduledoc """
  Undo as whole-document snapshots, newest first and capped at 100.

  A snapshot makes a composite edit one undo entry with no inverse operations.
  There is no redo.
  """

  alias Domovoy.Composer.Document

  @cap 100

  @opaque t :: [{Document.t(), atom()}]

  @doc """
  An empty history.
  """
  @spec reset() :: t()
  def reset, do: []

  @doc """
  Records the document as it was before an edit of `kind`.
  """
  @spec push(history :: t(), document :: Document.t(), kind :: atom()) :: t()
  def push(history, document, kind), do: Enum.take([{document, kind} | history], @cap)

  @doc """
  Takes the newest snapshot, or `:empty`.
  """
  @spec undo(history :: t()) :: {Document.t(), atom(), t()} | :empty
  def undo([{document, kind} | history]), do: {document, kind, history}
  def undo([]), do: :empty

  @doc """
  Whether there is nothing to undo.
  """
  @spec empty?(history :: t()) :: boolean()
  def empty?(history), do: history == []
end
