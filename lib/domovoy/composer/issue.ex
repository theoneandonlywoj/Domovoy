defmodule Domovoy.Composer.Issue do
  @moduledoc """
  One problem with a draft or an edit.

  `code` is a host atom. `core_id` is set only when the issue mirrors a Core
  identifier. A message is built from identifiers and type labels, never from a
  literal value, so a secret typed into a literal can't reach one.
  """

  @type target ::
          :workflow
          | {:vertex, String.t()}
          | {:node, String.t(), String.t()}
          | {:field, String.t(), String.t(), String.t()}
          | {:after, String.t(), String.t(), String.t()}
          | {:input, String.t()}
          | {:choice, String.t(), String.t()}

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          core_id: atom() | nil,
          target: target(),
          adapters: [%{id: String.t(), label: String.t()}]
        }

  defstruct [:code, :message, :core_id, :target, adapters: []]
end
