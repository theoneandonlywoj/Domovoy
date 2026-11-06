defmodule Domovoy.Examples.Definitions do
  @moduledoc """
  The seeded example workflows, ported from Core's `ensure_worktree` and
  `cracow_house_price` notebooks. Each is built only through `Operations.edit/2`, so
  it can hold nothing the composer's write path refuses.

  Cards read left to right: a card's sources sit in a column before it, and cards of
  one column stack. A node card is 320 wide and a vertex card 280.
  """

  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Operations

  @string "DomovoyCore.Type.String"
  @integer "DomovoyCore.Type.Integer"
  @boolean "DomovoyCore.Type.Boolean"
  @directory "DomovoyCore.Type.Directory"

  @git_runner "DomovoyGitPlugin.Runner"
  @mise_runner "DomovoyMisePlugin.Runner"
  @worktree "Domovoy.Examples.Worktree"
  @cracow "Domovoy.Examples.Cracow"
  @float "#{@cracow}.Float"

  @doc """
  Every example, in seeding order. Raises when an op is refused, naming only the op
  and the issue code.
  """
  @spec all() :: [%{title: String.t(), document: Document.t()}]
  def all do
    [
      %{title: "Create a worktree", document: create_worktree()},
      %{title: "Cracow house price", document: cracow_house_price()}
    ]
  end

  @doc """
  The `create_worktree` workflow.
  """
  @spec create_worktree() :: Document.t()
  def create_worktree do
    build("create_worktree", [
      {:put_input, "repository_path", %{"type" => @directory}},
      {:put_input, "branch_name", %{"type" => @string}},
      {:put_input, "base_branch", %{"type" => @string, "default" => "main"}},
      {:add_stage, "inspect"},
      {:set_start, "inspect"},
      {:remove_vertex, "main"},
      {:add_decision, "route"},
      {:add_stage, "create"},
      {:add_stage, "sync"},
      {:add_stage, "finalize"},
      {:add_node, "inspect", "#{@git_runner}.WorktreeName", "worktree_name"},
      {:add_node, "inspect", "#{@git_runner}.WorktreeResolve", "resolve"},
      {:add_node, "create", "#{@git_runner}.WorktreeCreate", "create_worktree"},
      {:add_node, "sync", "#{@worktree}.WorktreeSyncFolder", "sync_build"},
      {:add_node, "sync", "#{@worktree}.WorktreeSyncFolder", "sync_deps"},
      {:add_node, "finalize", "#{@git_runner}.WorktreeResolve", "result"},
      {:add_node, "finalize", "#{@mise_runner}.Detect", "mise"},
      {:add_node, "finalize", "#{@mise_runner}.Trust", "trust"},
      {:add_node, "finalize", "#{@worktree}.MiseCurrent", "mise_current"},
      bind("inspect", "worktree_name", "target_branch", "branch_name"),
      bind("inspect", "resolve", "worktree_name", "worktree_name"),
      bind("inspect", "resolve", "working_directory", "repository_path"),
      bind("create", "create_worktree", "worktree_name", "worktree_name"),
      bind("create", "create_worktree", "branch_name", "branch_name"),
      bind("create", "create_worktree", "base_branch", "base_branch"),
      bind("create", "create_worktree", "working_directory", "repository_path"),
      bind("sync", "sync_build", "worktree", "resolve"),
      {:set_literal, "sync", "sync_build", "folder", "_build", replace_binding: false},
      bind("sync", "sync_deps", "worktree", "resolve"),
      {:set_literal, "sync", "sync_deps", "folder", "deps", replace_binding: false},
      bind("finalize", "result", "worktree_name", "worktree_name"),
      bind("finalize", "result", "working_directory", "repository_path"),
      bind("finalize", "trust", "worktree", "result"),
      bind("finalize", "trust", "mise", "mise"),
      bind("finalize", "mise_current", "worktree", "trust"),
      bind("finalize", "mise_current", "mise", "mise"),
      {:set_next, "inspect", "route"},
      {:set_next, "create", "sync"},
      {:set_next, "sync", "finalize"},
      {:put_decision, "route",
       %{
         "prompt" => "Create or use existing?",
         "decider" => "#{@worktree}.WorktreeRouteDecider"
       }},
      {:put_choice, "route",
       %{"name" => "create", "description" => "Create it.", "target" => ["run", "create"]}},
      {:put_choice, "route",
       %{"name" => "existing", "description" => "Use existing.", "target" => ["run", "sync"]}},
      {:move, :workflow, "inspect", 60, 300},
      {:move, :workflow, "route", 440, 300},
      {:move, :workflow, "create", 820, 80},
      {:move, :workflow, "sync", 1200, 300},
      {:move, :workflow, "finalize", 1580, 300},
      {:move, {:stage, "inspect"}, "worktree_name", 60, 80},
      {:move, {:stage, "inspect"}, "resolve", 480, 80},
      {:move, {:stage, "create"}, "create_worktree", 60, 80},
      {:move, {:stage, "sync"}, "sync_build", 60, 80},
      {:move, {:stage, "sync"}, "sync_deps", 60, 360},
      {:move, {:stage, "finalize"}, "result", 60, 80},
      {:move, {:stage, "finalize"}, "mise", 60, 400},
      {:move, {:stage, "finalize"}, "trust", 480, 80},
      # mise's wire to mise_current runs straight, under trust.
      {:move, {:stage, "finalize"}, "mise_current", 900, 346}
    ])
  end

  @doc """
  The `cracow_prices` workflow, the name its notebook gives it.
  """
  @spec cracow_house_price() :: Document.t()
  def cracow_house_price do
    build("cracow_prices", [
      {:put_input, "rooms", %{"type" => @integer}},
      {:put_input, "bathrooms", %{"type" => @integer}},
      {:put_input, "area", %{"type" => @float}},
      {:put_input, "district", %{"type" => @string}},
      {:put_input, "floor", %{"type" => @integer}},
      {:put_input, "balcony", %{"type" => @boolean}},
      {:put_input, "year_built", %{"type" => @integer}},
      {:add_stage, "estimate_price"},
      {:set_start, "estimate_price"},
      {:remove_vertex, "main"},
      {:add_node, "estimate_price", "#{@cracow}.Normalize", "normalize"},
      {:add_node, "estimate_price", "#{@cracow}.AreaModel", "area_model"},
      {:add_node, "estimate_price", "#{@cracow}.LayoutModel", "layout_model"},
      {:add_node, "estimate_price", "#{@cracow}.LocationModel", "location_model"},
      {:add_node, "estimate_price", "#{@cracow}.Estimate", "estimate"},
      bind("estimate_price", "normalize", "rooms", "rooms"),
      bind("estimate_price", "normalize", "bathrooms", "bathrooms"),
      bind("estimate_price", "normalize", "area", "area"),
      bind("estimate_price", "normalize", "district", "district"),
      bind("estimate_price", "normalize", "floor", "floor"),
      bind("estimate_price", "normalize", "balcony", "balcony"),
      bind("estimate_price", "normalize", "year_built", "year_built"),
      {:set_validators, "estimate_price", "normalize",
       ["#{@cracow}.RoomLayout", "#{@cracow}.AreaPolicy"]},
      bind("estimate_price", "area_model", "features", "normalize"),
      bind("estimate_price", "layout_model", "features", "normalize"),
      bind("estimate_price", "location_model", "features", "normalize"),
      bind("estimate_price", "estimate", "features", "normalize"),
      bind("estimate_price", "estimate", "base", "area_model"),
      bind("estimate_price", "estimate", "layout", "layout_model"),
      bind("estimate_price", "estimate", "location", "location_model"),
      {:move, :workflow, "estimate_price", 60, 80},
      # normalize's wire to estimate runs straight, between layout_model and location_model.
      {:move, {:stage, "estimate_price"}, "normalize", 60, 144},
      {:move, {:stage, "estimate_price"}, "area_model", 480, 80},
      {:move, {:stage, "estimate_price"}, "layout_model", 480, 300},
      {:move, {:stage, "estimate_price"}, "location_model", 480, 640},
      {:move, {:stage, "estimate_price"}, "estimate", 900, 490}
    ])
  end

  @spec bind(stage :: String.t(), node :: String.t(), field :: String.t(), source :: String.t()) ::
          tuple()
  defp bind(stage, node, field, source),
    do: {:bind, stage, node, field, source, replace_literal: false}

  @spec build(name :: String.t(), ops :: [tuple()]) :: Document.t()
  defp build(name, ops) do
    Enum.reduce(ops, Document.new(name), fn op, document ->
      case Operations.edit(document, op) do
        {:ok, updated, _kind} ->
          updated

        {:error, issue} ->
          raise "Seed #{name}: #{elem(op, 0)} was refused with #{issue.code}"
      end
    end)
  end
end
