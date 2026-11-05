defmodule Domovoy.ComposerFixtures do
  @moduledoc """
  The canonical scenario A document, built only through `Operations.edit/2`, so the
  fixture can't hold anything the write path refuses.
  """

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Operations

  @string "DomovoyCore.Type.String"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @trust "DomovoyMisePlugin.Runner.Trust"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"

  @doc """
  Scenario A: stage `prepare`, then Decision `review`.
  """
  @spec scenario_a() :: Document.t()
  def scenario_a do
    edit_all(Document.new("scenario_a"), [
      {:put_input, "worktree_name", %{"type" => @string, "required" => true}},
      {:put_input, "prompt", %{"type" => @string, "required" => true}},
      {:add_stage, "prepare"},
      {:set_start, "prepare"},
      {:remove_vertex, "main"},
      {:add_node, "prepare", @resolve, "resolve_worktree"},
      {:add_node, "prepare", @directory, "worktree_directory"},
      {:add_node, "prepare", @detect, "detect_mise"},
      {:add_node, "prepare", @trust, "trust_mise"},
      {:add_node, "prepare", @ask, "ask_claude"},
      bind("resolve_worktree", "worktree_name", "worktree_name"),
      bind("worktree_directory", "worktree", "resolve_worktree"),
      bind("trust_mise", "worktree", "resolve_worktree"),
      bind("trust_mise", "mise", "detect_mise"),
      bind("ask_claude", "context", "prompt"),
      bind("ask_claude", "working_directory", "worktree_directory"),
      {:set_literal, "prepare", "ask_claude", "options", "{}", replace_binding: false},
      {:add_after, "prepare", "ask_claude", "trust_mise"},
      {:add_decision, "review"},
      {:set_next, "prepare", "review"},
      {:put_decision, "review", %{"prompt" => "Approve the answer?"}},
      {:put_choice, "review",
       %{"name" => "approve", "description" => "Accept", "target" => ["halt"]}},
      {:put_choice, "review",
       %{
         "name" => "revise",
         "description" => "Ask again",
         "target" => ["rerun", "prepare"],
         "inputs" => %{"prompt" => @string}
       }}
    ])
  end

  @doc """
  Saves a document as a new draft.
  """
  @spec draft!(document :: Document.t(), title :: String.t()) :: Draft.t()
  def draft!(document, title \\ "Draft") do
    {:ok, draft} = Composer.create_draft(%{title: title})
    {:ok, saved} = Composer.save_document(draft, document)
    saved
  end

  @doc """
  Reads a draft's saved document.
  """
  @spec saved_document(draft :: Draft.t() | %{id: String.t()}) :: Document.t()
  def saved_document(draft) do
    {:ok, %Draft{document: document}} = Composer.get_draft(draft.id)
    document
  end

  @doc """
  Applies ops in order, raising on any rejection.
  """
  @spec edit_all(document :: Document.t(), ops :: [tuple()]) :: Document.t()
  def edit_all(document, ops) do
    Enum.reduce(ops, document, fn op, acc ->
      {:ok, updated, _kind} = Operations.edit(acc, op)
      updated
    end)
  end

  @spec bind(node :: String.t(), field :: String.t(), source :: String.t()) :: tuple()
  defp bind(node, field, source),
    do: {:bind, "prepare", node, field, source, replace_literal: false}
end
