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
    worktree_name = {"derive_worktree_name", Type.String}
    repository = {"repository_path", Type.Directory}

    derive_worktree_name_node =
      Node.new(%{
        name: "derive_worktree_name",
        runner: WorktreeName,
        type: Type.String,
        bind: %{target_branch: {"branch_name", Type.String}}
      })

    resolve_bind = %{worktree_name: worktree_name, working_directory: repository}

    look_up_worktree_node =
      Node.new(%{
        name: "look_up_worktree",
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

    describe_synced_worktree_node =
      Node.new(%{
        name: "describe_synced_worktree",
        runner: WorktreeResolve,
        type: WorktreeType,
        bind: resolve_bind
      })

    sync_build_node =
      Node.new(%{
        name: "sync_build",
        runner: Worktree.WorktreeSyncFolder,
        type: Type.Map,
        bind: %{worktree: {"look_up_worktree", WorktreeType}},
        args: %{folder: {"_build", Type.String}}
      })

    sync_deps_node =
      Node.new(%{
        name: "sync_deps",
        runner: Worktree.WorktreeSyncFolder,
        type: Type.Map,
        bind: %{worktree: {"look_up_worktree", WorktreeType}},
        args: %{folder: {"deps", Type.String}}
      })

    detect_mise_node = Node.new(%{name: "detect_mise", runner: Detect, type: Executable})

    trust_mise_config_node =
      Node.new(%{
        name: "trust_mise_config",
        runner: Trust,
        type: Type.Map,
        bind: %{
          worktree: {"describe_synced_worktree", Type.Any},
          mise: {"detect_mise", Executable}
        }
      })

    read_mise_versions_node =
      Node.new(%{
        name: "read_mise_versions",
        runner: Worktree.MiseCurrent,
        type: Worktree.MiseCurrentVersions,
        bind: %{worktree: {"trust_mise_config", Type.Any}, mise: {"detect_mise", Executable}}
      })

    %{
      "inspect_worktree" =>
        Stage.new(%{
          name: "inspect_worktree",
          graph: Graph.new([derive_worktree_name_node, look_up_worktree_node]),
          next: "choose_create_or_use_worktree"
        }),
      "choose_create_or_use_worktree" =>
        Decision.new(%{
          name: "choose_create_or_use_worktree",
          prompt: "Create or use existing?",
          choices: [
            Choice.new(%{
              name: "create_missing_worktree",
              description: "Create it.",
              target: {:run, "create_missing_worktree"}
            }),
            Choice.new(%{
              name: "use_existing_worktree",
              description: "Use existing.",
              target: {:run, "sync_worktree_folders"}
            })
          ],
          # The decider reads the worktree from the node its options name.
          decider: {Worktree.WorktreeRouteDecider, node: "look_up_worktree"}
        }),
      "create_missing_worktree" =>
        Stage.new(%{
          name: "create_missing_worktree",
          graph: Graph.new([create_worktree_node]),
          next: "sync_worktree_folders"
        }),
      "sync_worktree_folders" =>
        Stage.new(%{
          name: "sync_worktree_folders",
          graph: Graph.new([sync_build_node, sync_deps_node]),
          next: "finish_worktree_setup"
        }),
      "finish_worktree_setup" =>
        Stage.new(%{
          name: "finish_worktree_setup",
          graph:
            Graph.new([
              describe_synced_worktree_node,
              detect_mise_node,
              trust_mise_config_node,
              read_mise_versions_node
            ])
        })
    }
  end

  defp cracow_vertices do
    graph =
      Graph.new([
        Node.new(%{
          name: "normalize_listing",
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
          bind: %{features: {"normalize_listing", Cracow.Features}}
        }),
        Node.new(%{
          name: "layout_model",
          runner: Cracow.LayoutModel,
          type: Cracow.Float,
          bind: %{features: {"normalize_listing", Cracow.Features}}
        }),
        Node.new(%{
          name: "location_model",
          runner: Cracow.LocationModel,
          type: Cracow.Float,
          bind: %{features: {"normalize_listing", Cracow.Features}}
        }),
        Node.new(%{
          name: "join_price_terms",
          runner: Cracow.Estimate,
          type: Type.Map,
          bind: %{
            features: {"normalize_listing", Cracow.Features},
            base: {"area_model", Cracow.Float},
            layout: {"layout_model", Cracow.Float},
            location: {"location_model", Cracow.Float}
          }
        })
      ])

    %{"estimate_price" => Stage.new(%{name: "estimate_price", graph: graph})}
  end

  describe "the seeded definitions" do
    test "create_worktree is valid and holds the vertices its notebook builds" do
      workflow = valid_workflow(strip_descriptions(Definitions.create_worktree()))

      assert workflow.name == "create_worktree"
      assert workflow.start == "inspect_worktree"
      assert workflow.vertices == worktree_vertices()

      assert workflow.inputs == %{
               "repository_path" => %{type: Type.Directory, required: false},
               "branch_name" => %{type: Type.String, required: false},
               "base_branch" => %{type: Type.String, default: "main", required: false}
             }
    end

    test "cracow_prices is valid and holds the vertices its notebook builds" do
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
    test "cover all 19 nodes, 8 vertices and 17 inputs, in 1 to 3 sentences, distinct per seed" do
      items = Enum.map(Definitions.all(), &described_items(&1.document))
      count = fn kind -> items |> Enum.map(&length(&1[kind])) |> Enum.sum() end

      assert {count.(:nodes), count.(:vertices), count.(:inputs)} == {19, 8, 17}

      texts_per_seed =
        for item_kinds <- items do
          for {_kind, kind_items} <- item_kinds, item <- kind_items do
            assert {:ok, text} = Document.description(item)
            text
          end
        end

      assert texts_per_seed |> List.flatten() |> length() == 44

      for texts <- texts_per_seed do
        assert Enum.uniq(texts) == texts

        for text <- texts do
          assert String.ends_with?(text, "."), text
          assert length(String.split(text, ~r/\.(\s|$)/, trim: true)) in 1..3, text
        end
      end
    end

    test "keep the seeds valid, with the fingerprint root they have without them" do
      for %{document: document} <- Definitions.all() do
        workflow = valid_workflow(document)
        plain = valid_workflow(strip_descriptions(document))

        assert Definition.fingerprint(workflow).root == Definition.fingerprint(plain).root
      end
    end

    @input_descriptions %{
      "repository_path" =>
        "The Git repository the worktree belongs to. Looking up and creating the worktree " <>
          "both run from this directory.",
      "branch_name" =>
        "The branch the worktree should be on. Its last path segment becomes the worktree " <>
          "name, and an existing worktree must already be on this branch.",
      "base_branch" =>
        "The ref a new branch starts from, main unless set. It is used only when the " <>
          "worktree is created.",
      "rooms" => "Number of rooms, at least 1 and no fewer than the bathrooms.",
      "bathrooms" => "Number of bathrooms, at least 1 and no more than the rooms.",
      "area" => "Floor area in square metres, from 15 to 300.",
      "district" => "The Kraków district, which must be one of the nine the price model knows.",
      "floor" =>
        "The floor the flat is on, 0 or higher. The ground floor lowers the price, and " <>
          "floor 5 and above raises it.",
      "balcony" => "Whether the flat has a balcony, which raises the price.",
      "year_built" =>
        "The year the building was built. Buildings from before 1960 or from 2015 on " <>
          "raise the price, and those from 1960 to 1989 lower it."
    }

    test "reach the exported JSON on every input of each seeded workflow" do
      exported =
        for %{document: document} <- Definitions.all(),
            {name, input} <- exported_inputs(document) do
          assert input["metadata"] == %{"description" => @input_descriptions[name]}, name
          name
        end

      assert exported |> Enum.uniq() |> Enum.sort() == Enum.sort(Map.keys(@input_descriptions))
      assert length(exported) == 17
    end

    defp exported_inputs(document) do
      assert {:valid, %{json: json}} = Composer.validate(document)
      Jason.decode!(json)["inputs"]
    end

    test "export on each node, vertex and input, and leave workflow metadata alone" do
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

        for {name, input} <- document["inputs"] do
          assert {:ok, text} = Document.description(input)
          assert workflow.inputs[name][:metadata] == %{"description" => text}
        end
      end
    end
  end

  defp routes(document) do
    Enum.flat_map(document["vertices"], fn
      {_name, %{"kind" => "stage", "next" => nil}} -> []
      {name, %{"kind" => "stage", "next" => next}} -> [{name, next}]
      {name, %{"choices" => choices}} -> for %{"target" => ["run", to]} <- choices, do: {name, to}
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
