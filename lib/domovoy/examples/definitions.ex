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
    build(
      "create_worktree",
      [
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
      ] ++ worktree_descriptions()
    )
  end

  @doc """
  The `cracow_prices` workflow, the name its notebook gives it.
  """
  @spec cracow_house_price() :: Document.t()
  def cracow_house_price do
    build(
      "cracow_prices",
      [
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
      ] ++ cracow_descriptions()
    )
  end

  @spec worktree_descriptions() :: [tuple()]
  defp worktree_descriptions do
    [
      {:set_description, {:input, "repository_path"},
       "The Git repository the worktree belongs to. Looking up and creating the worktree" <>
         " both run from this directory."},
      {:set_description, {:input, "branch_name"},
       "The branch the worktree should be on. Its last path segment becomes the worktree" <>
         " name, and an existing worktree must already be on this branch."},
      {:set_description, {:input, "base_branch"},
       "The ref a new branch starts from, main unless set. It is used only when the " <>
         "worktree is created."},
      {:set_description, {:vertex, "inspect"},
       "Works out the worktree name from the branch and checks whether that worktree " <>
         "already exists. It changes nothing on disk."},
      {:set_description, {:vertex, "route"},
       "Picks the next step automatically, with no person involved: a missing worktree " <>
         "goes to creation, and one already on the wanted branch goes straight to syncing." <>
         " A worktree on a different branch is an error."},
      {:set_description, {:vertex, "create"},
       "Runs only when the worktree is missing, and creates it on a new branch."},
      {:set_description, {:vertex, "sync"},
       "Brings the worktree's build output and dependencies in line with the main " <>
         "checkout. It runs whether the worktree was just created or already existed."},
      {:set_description, {:vertex, "finalize"},
       "Reads the worktree's final state, trusts its Mise config when Mise is installed," <>
         " and reports the tool versions. This is the last stage."},
      {:set_description, {:node, "inspect", "worktree_name"},
       "Keeps the last path segment of the branch name to use as the worktree name. " <>
         "Whether the name is safe is checked where it is used."},
      {:set_description, {:node, "inspect", "resolve"},
       "Looks up the managed worktree under .worktrees in the main checkout and " <>
         "describes it. A missing worktree is reported as not existing, not as an error, " <>
         "and nothing is changed."},
      {:set_description, {:node, "create", "create_worktree"},
       "Creates the worktree under .worktrees in the main checkout, on a new branch from" <>
         " the base branch, and records that base branch. It fails if the path is already " <>
         "taken."},
      {:set_description, {:node, "sync", "sync_build"},
       "Makes the worktree's _build folder match the main checkout's, copying it when it" <>
         " is missing and replacing it when it differs. If the main checkout has no " <>
         "_build, the node fails and leaves the worktree's copy alone."},
      {:set_description, {:node, "sync", "sync_deps"},
       "Makes the worktree's deps folder match the main checkout's, copying it when it " <>
         "is missing and replacing it when it differs. If the main checkout has no deps, " <>
         "the node fails and leaves the worktree's copy alone."},
      {:set_description, {:node, "finalize", "result"},
       "Describes the worktree again now that it exists and is synced, for the later " <>
         "steps to use. Its created flag stays false even when this run created the " <>
         "worktree."},
      {:set_description, {:node, "finalize", "mise"},
       "Looks for the mise executable on the PATH. Mise is optional, so not finding it " <>
         "is reported as unavailable instead of failing."},
      {:set_description, {:node, "finalize", "trust"},
       "Trusts the Mise config in the worktree, because Mise ignores a new worktree's " <>
         "config until it is trusted. Without Mise it logs a warning and carries on."},
      {:set_description, {:node, "finalize", "mise_current"},
       "Runs mise current in the worktree to show the tool versions it resolves to. " <>
         "Without Mise it gives no tools."}
    ]
  end

  @spec cracow_descriptions() :: [tuple()]
  defp cracow_descriptions do
    [
      {:set_description, {:input, "rooms"},
       "Number of rooms, at least 1 and no fewer than the bathrooms."},
      {:set_description, {:input, "bathrooms"},
       "Number of bathrooms, at least 1 and no more than the rooms."},
      {:set_description, {:input, "area"}, "Floor area in square metres, from 15 to 300."},
      {:set_description, {:input, "district"},
       "The Kraków district, which must be one of the nine the price model knows."},
      {:set_description, {:input, "floor"},
       "The floor the flat is on, 0 or higher. The ground floor lowers the price, and " <>
         "floor 5 and above raises it."},
      {:set_description, {:input, "balcony"},
       "Whether the flat has a balcony, which raises the price."},
      {:set_description, {:input, "year_built"},
       "The year the building was built. Buildings from before 1960 or from 2015 on " <>
         "raise the price, and those from 1960 to 1989 lower it."},
      {:set_description, {:vertex, "estimate_price"},
       "The only stage of this workflow. It checks the listing, runs three separate " <>
         "pricing steps on it, and joins their results into one price."},
      {:set_description, {:node, "estimate_price", "normalize"},
       "Checks that the listing could be a real flat in Kraków and turns it into one " <>
         "features value for the pricing steps. It also works out the area per room."},
      {:set_description, {:node, "estimate_price", "area_model"},
       "Gives the flat's base value in PLN from its area alone, with the price per " <>
         "square metre falling up to about 130 square metres and rising after that. Like " <>
         "the other pricing steps, it uses a simple formula with made-up coefficients, not" <>
         " one fitted to real listings."},
      {:set_description, {:node, "estimate_price", "layout_model"},
       "Gives a price multiplier from the rooms and bathrooms, reduced when there are " <>
         "too many rooms for the area. Its coefficients are made up."},
      {:set_description, {:node, "estimate_price", "location_model"},
       "Gives a price multiplier from the district, floor, balcony and building age. Its" <>
         " coefficients are made up."},
      {:set_description, {:node, "estimate_price", "estimate"},
       "Multiplies the base value by the layout and location multipliers to give the " <>
         "price. It returns the price, the price per square metre and the three " <>
         "components."}
    ]
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
