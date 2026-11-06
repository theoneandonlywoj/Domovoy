defmodule Domovoy.Examples.DefinitionsTest do
  # Not async: the no-execution trace is global.
  use ExUnit.Case, async: false

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Examples.Cracow
  alias Domovoy.Examples.Definitions
  alias Domovoy.Examples.Worktree
  alias Domovoy.NoExecutionTrace
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Definition
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Type
  alias DomovoyGitPlugin.Runner.WorktreeCreate
  alias DomovoyGitPlugin.Runner.WorktreeName
  alias DomovoyGitPlugin.Runner.WorktreeResolve
  alias DomovoyGitPlugin.Type.Worktree, as: WorktreeType
  alias DomovoyMisePlugin.Runner.Detect
  alias DomovoyMisePlugin.Runner.Trust
  alias DomovoyMisePlugin.Type.Executable

  defp valid_workflow(document) do
    report = NoExecutionTrace.run(fn -> Composer.validate(document) end)

    assert {:valid, %{workflow: workflow, json: json}} = report.result
    assert is_binary(json)
    assert report.traced != []
    assert Enum.all?(report.controls_expected, &(&1 in report.control_calls))
    assert report.forbidden_calls == []

    workflow
  end

  # The seed without what its description ops wrote, to compare with the notebook.
  defp strip_descriptions(document) do
    document
    |> Map.update!("inputs", &strip_metadata/1)
    |> Map.update!("vertices", fn vertices ->
      vertices |> strip_metadata() |> Map.new(&strip_nodes/1)
    end)
  end

  defp strip_nodes({name, %{"nodes" => nodes} = stage}),
    do: {name, %{stage | "nodes" => strip_metadata(nodes)}}

  defp strip_nodes(decision), do: decision

  defp strip_metadata(items),
    do: Map.new(items, fn {name, item} -> {name, Map.delete(item, "metadata")} end)

  # Every item a seed describes, by kind.
  defp described_items(document) do
    nodes =
      for {_stage, %{"nodes" => nodes}} <- document["vertices"], {_name, node} <- nodes, do: node

    %{
      nodes: nodes,
      vertices: Map.values(document["vertices"]),
      inputs: Map.values(document["inputs"])
    }
  end

  # The vertices as each notebook's cells build them, with its node validators.
  defp worktree_vertices do
    worktree_name = {"worktree_name", Type.String}
    repository = {"repository_path", Type.Directory}

    worktree_name_node =
      Node.new(%{
        name: "worktree_name",
        runner: WorktreeName,
        type: Type.String,
        bind: %{target_branch: {"branch_name", Type.String}}
      })

    resolve_bind = %{worktree_name: worktree_name, working_directory: repository}

    resolve_node =
      Node.new(%{
        name: "resolve",
        runner: WorktreeResolve,
        type: WorktreeType,
        bind: resolve_bind
      })

    create_worktree_node =
      Node.new(%{
        name: "create_worktree",
        runner: WorktreeCreate,
        type: WorktreeType,
        bind: %{
          worktree_name: worktree_name,
          branch_name: {"branch_name", Type.String},
          base_branch: {"base_branch", Type.String},
          working_directory: repository
        }
      })

    result_node =
      Node.new(%{name: "result", runner: WorktreeResolve, type: WorktreeType, bind: resolve_bind})

    sync_build_node =
      Node.new(%{
        name: "sync_build",
        runner: Worktree.WorktreeSyncFolder,
        type: Type.Map,
        bind: %{worktree: {"resolve", WorktreeType}},
        args: %{folder: {"_build", Type.String}}
      })

    sync_deps_node =
      Node.new(%{
        name: "sync_deps",
        runner: Worktree.WorktreeSyncFolder,
        type: Type.Map,
        bind: %{worktree: {"resolve", WorktreeType}},
        args: %{folder: {"deps", Type.String}}
      })

    mise_node = Node.new(%{name: "mise", runner: Detect, type: Executable})

    trust_node =
      Node.new(%{
        name: "trust",
        runner: Trust,
        type: Type.Map,
        bind: %{worktree: {"result", Type.Any}, mise: {"mise", Executable}}
      })

    mise_current_node =
      Node.new(%{
        name: "mise_current",
        runner: Worktree.MiseCurrent,
        type: Worktree.MiseCurrentVersions,
        bind: %{worktree: {"trust", Type.Any}, mise: {"mise", Executable}}
      })

    %{
      "inspect" =>
        Stage.new(%{
          name: "inspect",
          graph: Graph.new([worktree_name_node, resolve_node]),
          next: "route"
        }),
      "route" =>
        Decision.new(%{
          name: "route",
          prompt: "Create or use existing?",
          choices: [
            Choice.new(%{name: "create", description: "Create it.", target: {:run, "create"}}),
            Choice.new(%{name: "existing", description: "Use existing.", target: {:run, "sync"}})
          ],
          # The notebook writes `{module, []}`: the same decider, with the same no options.
          decider: Worktree.WorktreeRouteDecider
        }),
      "create" =>
        Stage.new(%{name: "create", graph: Graph.new([create_worktree_node]), next: "sync"}),
      "sync" =>
        Stage.new(%{
          name: "sync",
          graph: Graph.new([sync_build_node, sync_deps_node]),
          next: "finalize"
        }),
      "finalize" =>
        Stage.new(%{
          name: "finalize",
          graph: Graph.new([result_node, mise_node, trust_node, mise_current_node])
        })
    }
  end

  defp cracow_vertices do
    graph =
      Graph.new([
        Node.new(%{
          name: "normalize",
          runner: Cracow.Normalize,
          type: Cracow.Features,
          validators: [Cracow.RoomLayout, Cracow.AreaPolicy],
          bind: %{
            rooms: {"rooms", Type.Integer},
            bathrooms: {"bathrooms", Type.Integer},
            area: {"area", Cracow.Float},
            district: {"district", Type.String},
            floor: {"floor", Type.Integer},
            balcony: {"balcony", Type.Boolean},
            year_built: {"year_built", Type.Integer}
          }
        }),
        Node.new(%{
          name: "area_model",
          runner: Cracow.AreaModel,
          type: Cracow.Float,
          bind: %{features: {"normalize", Cracow.Features}}
        }),
        Node.new(%{
          name: "layout_model",
          runner: Cracow.LayoutModel,
          type: Cracow.Float,
          bind: %{features: {"normalize", Cracow.Features}}
        }),
        Node.new(%{
          name: "location_model",
          runner: Cracow.LocationModel,
          type: Cracow.Float,
          bind: %{features: {"normalize", Cracow.Features}}
        }),
        Node.new(%{
          name: "estimate",
          runner: Cracow.Estimate,
          type: Type.Map,
          bind: %{
            features: {"normalize", Cracow.Features},
            base: {"area_model", Cracow.Float},
            layout: {"layout_model", Cracow.Float},
            location: {"location_model", Cracow.Float}
          }
        })
      ])

    %{"estimate_price" => Stage.new(%{name: "estimate_price", graph: graph})}
  end

  describe "the seeded definitions" do
    test "create_worktree is valid and equals its notebook" do
      workflow = valid_workflow(strip_descriptions(Definitions.create_worktree()))

      assert workflow.name == "create_worktree"
      assert workflow.start == "inspect"
      assert workflow.vertices == worktree_vertices()

      assert workflow.inputs == %{
               "repository_path" => %{type: Type.Directory, required: false},
               "branch_name" => %{type: Type.String, required: false},
               "base_branch" => %{type: Type.String, default: "main", required: false}
             }
    end

    test "cracow_prices is valid and equals its notebook" do
      workflow = valid_workflow(strip_descriptions(Definitions.cracow_house_price()))

      assert workflow.name == "cracow_prices"
      assert workflow.start == "estimate_price"
      assert workflow.vertices == cracow_vertices()

      inputs = Map.new(workflow.inputs, fn {name, input} -> {name, input.type} end)
      assert inputs == Stage.inputs(workflow.vertices["estimate_price"])
    end

    test "place cards with no overlap and every wire running left to right" do
      for %{document: document} <- Definitions.all() do
        assert_left_to_right(
          document["layout"]["workflow"],
          routes(document),
          280
        )

        for {stage, %{"kind" => "stage", "nodes" => nodes}} <- document["vertices"] do
          sources =
            for {name, node} <- nodes,
                {_field, %{"bind" => source}} <- node["inputs"],
                is_map_key(nodes, source) do
              {source, name}
            end

          assert_left_to_right(document["layout"]["stages"][stage], sources, 320)
        end
      end
    end
  end

  describe "the seeded descriptions" do
    test "cover all 14 nodes, 6 vertices and 10 inputs, in distinct 1 to 3 sentences" do
      items = Enum.map(Definitions.all(), &described_items(&1.document))
      count = fn kind -> items |> Enum.map(&length(&1[kind])) |> Enum.sum() end

      assert {count.(:nodes), count.(:vertices), count.(:inputs)} == {14, 6, 10}

      texts =
        for item_kinds <- items, {_kind, kind_items} <- item_kinds, item <- kind_items do
          assert {:ok, text} = Document.description(item)
          text
        end

      assert length(texts) == 30
      assert Enum.uniq(texts) == texts

      for text <- texts do
        assert String.ends_with?(text, "."), text
        assert length(String.split(text, ~r/\.(\s|$)/, trim: true)) in 1..3, text
      end
    end

    test "keep the seeds valid, with the fingerprint root they have without them" do
      for %{document: document} <- Definitions.all() do
        workflow = valid_workflow(document)
        plain = valid_workflow(strip_descriptions(document))

        assert Definition.fingerprint(workflow).root == Definition.fingerprint(plain).root
      end
    end

    test "export on each node and vertex, and leave inputs and workflow metadata alone" do
      for %{document: document} <- Definitions.all() do
        workflow = valid_workflow(document)

        for {name, vertex} <- document["vertices"] do
          built = workflow.vertices[name]
          assert {:ok, text} = Document.description(vertex)
          assert built.metadata == %{"description" => text}

          for {node_name, node} <- Map.get(vertex, "nodes", %{}) do
            assert {:ok, node_text} = Document.description(node)
            assert built.graph.nodes_by_name[node_name].metadata == %{"description" => node_text}
          end
        end

        assert Map.keys(workflow.metadata) == ["domovoy_editor"]

        for {_name, input} <- workflow.inputs do
          refute Map.has_key?(input, :metadata)
          refute Map.has_key?(input, "metadata")
        end
      end
    end
  end

  defp routes(document) do
    Enum.flat_map(document["vertices"], fn
      {_name, %{"kind" => "stage", "next" => nil}} -> []
      {name, %{"kind" => "stage", "next" => next}} -> [{name, next}]
      {name, %{"choices" => choices}} -> for %{"target" => [_, to]} <- choices, do: {name, to}
    end)
  end

  defp assert_left_to_right(placed, wires, width) do
    for {from, to} <- wires do
      assert placed[from]["x"] + width < placed[to]["x"], "#{from} -> #{to} runs backwards"
    end

    columns = placed |> Map.values() |> Enum.group_by(& &1["x"], & &1["y"])

    for {x, _ys} <- columns, other <- Map.keys(columns), other != x do
      assert abs(other - x) >= width, "columns #{x} and #{other} overlap"
    end

    # Stacked cards measure 182 to 231 tall in a browser, which checks the exact fit.
    for {_x, ys} <- columns,
        [upper, lower] <- ys |> Enum.sort() |> Enum.chunk_every(2, 1, :discard) do
      assert lower - upper >= 200
    end
  end

  describe "the ported runners" do
    @runners [
      {Worktree.WorktreeSyncFolder, Type.Map, [worktree: WorktreeType, folder: Type.String],
       [:worktree, :folder], []},
      {Worktree.MiseCurrent, Worktree.MiseCurrentVersions, [worktree: Type.Any, mise: Executable],
       [:worktree, :mise], []},
      {Cracow.Normalize, Cracow.Features,
       [
         rooms: Type.Integer,
         bathrooms: Type.Integer,
         area: Cracow.Float,
         district: Type.String,
         floor: Type.Integer,
         balcony: Type.Boolean,
         year_built: Type.Integer
       ], [:rooms, :bathrooms, :area, :district], [Cracow.Listing]},
      {Cracow.AreaModel, Cracow.Float, [features: Cracow.Features], [:features], []},
      {Cracow.LayoutModel, Cracow.Float, [features: Cracow.Features], [:features], []},
      {Cracow.LocationModel, Cracow.Float, [features: Cracow.Features], [:features], []},
      {Cracow.Estimate, Type.Map,
       [
         features: Cracow.Features,
         base: Cracow.Float,
         layout: Cracow.Float,
         location: Cracow.Float
       ], [:features, :base, :layout, :location], []}
    ]

    for {runner, output, fields, required, validators} <- @runners do
      test "#{inspect(runner)} declares the notebook's contract" do
        runner = unquote(runner)
        input = runner.__domovoy_core__(:input)

        assert runner.__domovoy_core__(:output) == unquote(output)
        assert Enum.sort(runner.__domovoy_core__(:required)) == Enum.sort(unquote(required))
        assert runner.__domovoy_core__(:validators) == unquote(validators)

        declared =
          for name <- input.__schema__(:fields), do: {name, input.__schema__(:type, name)}

        assert Enum.sort(declared) == Enum.sort(unquote(fields))
      end
    end

    test "Normalize keeps the notebook's defaults" do
      input = Cracow.Normalize.__domovoy_core__(:input)
      assert %{floor: 1, balcony: false, year_built: 2005} = struct(input)
    end

    test "the sync and mise runners keep the notebook's effects" do
      assert Worktree.WorktreeSyncFolder.__domovoy_core__(:effect).class == :non_idempotent
      assert Worktree.MiseCurrent.__domovoy_core__(:effect).class == :pure
    end
  end
end
