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
  One stage holding one test runner, `Domovoy.PureHoldRunner` by default, whose
  `trap_exit` comes from the input of that name. The node is `hold`.
  """
  @spec hold_run(runner :: module()) :: Document.t()
  def hold_run(runner \\ Domovoy.PureHoldRunner) do
    edit_all(Document.new("hold_run"), [
      {:put_input, "trap_exit", %{"type" => "DomovoyCore.Type.Boolean", "default" => "false"}},
      {:add_node, "main", inspect(runner), "hold"},
      {:bind, "main", "hold", "trap_exit", "trap_exit", replace_literal: false}
    ])
  end

  @doc """
  One stage holding a leak runner, `Domovoy.LeakRunner` by default, with `secret` and
  `mode` as inputs. The node is `leak`.
  """
  @spec leak_run(runner :: module()) :: Document.t()
  def leak_run(runner \\ Domovoy.LeakRunner) do
    edit_all(Document.new("leak_run"), [
      {:put_input, "secret", %{"type" => @string, "required" => true}},
      {:put_input, "mode", %{"type" => @string, "required" => true}},
      {:add_node, "main", inspect(runner), "leak"},
      {:bind, "main", "leak", "secret", "secret", replace_literal: false},
      {:bind, "main", "leak", "mode", "mode", replace_literal: false}
    ])
  end

  @doc """
  `hold_run/0` with a second node, `after_hold`, that needs `hold`'s output, so it
  can't run while `hold` is held.
  """
  @spec hold_pair() :: Document.t()
  def hold_pair do
    edit_all(hold_run(), [
      {:add_node, "main", "Domovoy.LeakRunner", "after_hold"},
      {:bind, "main", "after_hold", "secret", "hold", replace_literal: false},
      {:set_literal, "main", "after_hold", "mode", "succeed", replace_binding: false}
    ])
  end

  @doc """
  Core 0.3.3's file runners: `read` gives the bytes of the file at the `path` input,
  and `text` turns them into a string.
  """
  @spec read_file_run() :: Document.t()
  def read_file_run do
    edit_all(Document.new("read_file_run"), [
      {:put_input, "path", %{"type" => "DomovoyCore.Type.Path", "required" => true}},
      {:add_node, "main", "DomovoyCore.Runner.ReadFile", "read"},
      {:add_node, "main", "DomovoyCore.Runner.BinaryToString", "text"},
      {:bind, "main", "read", "path", "path", replace_literal: false},
      {:bind, "main", "text", "data", "read", replace_literal: false}
    ])
  end

  @doc """
  A `create_worktree`-style route with no Git: the `node` says the worktree is missing,
  and the curated `WorktreeRouteDecider`, reading that node, picks `create` on its own.
  Both choices halt.
  """
  @spec route_run(node :: String.t()) :: Document.t()
  def route_run(node \\ "resolve") do
    edit_all(Document.new("route_run"), [
      {:put_input, "branch_name", %{"type" => @string, "required" => true}},
      {:add_node, "main", "Domovoy.MissingWorktreeRunner", node},
      {:bind, "main", node, "branch_name", "branch_name", replace_literal: false},
      {:add_decision, "route"},
      {:set_next, "main", "route"},
      {:put_decision, "route",
       %{
         "prompt" => "Create or use existing?",
         "decider" => "Domovoy.Examples.Worktree.WorktreeRouteDecider",
         "decider_options" => %{"node" => node}
       }},
      {:put_choice, "route",
       %{"name" => "create", "description" => "Create it.", "target" => ["halt"]}},
      {:put_choice, "route",
       %{"name" => "existing", "description" => "Use existing.", "target" => ["halt"]}}
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
