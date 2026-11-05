defmodule Domovoy.Composer.Export do
  @moduledoc """
  The only decider of Definition valid: the analyzer finds nothing, real Core builds
  the workflow, and its JSON round trip is equal in struct, fingerprint root and
  bytes. Any failure is an issue; nothing raises. No runner, validator, decider or
  file-reading type runs, so nothing here says that a run would succeed.
  """

  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias DomovoyCore.Definition
  alias DomovoyCore.Workflow

  @type steps :: %{
          optional(:build) => (Document.t() -> term()),
          optional(:to_json) => (Workflow.t() -> term()),
          optional(:from_json) => (String.t() -> term())
        }

  @type result ::
          {:valid, %{workflow: Workflow.t(), json: String.t(), fingerprint: String.t()}}
          | {:invalid, [Issue.t()]}

  @doc """
  The real build, encode and decode.
  """
  @spec default_steps() :: %{
          build: (Document.t() -> term()),
          to_json: (Workflow.t() -> term()),
          from_json: (String.t() -> term())
        }
  def default_steps do
    %{
      build: &CoreBridge.build/1,
      to_json: &Workflow.to_json(&1, pretty: true),
      from_json: &Workflow.from_json/1
    }
  end

  @doc """
  Validates a document. `steps` overrides build, to_json or from_json, for tests.
  """
  @spec validate(document :: term(), steps :: steps()) :: result()
  def validate(document, steps \\ %{}) do
    steps = Map.merge(default_steps(), steps)

    with [] <- Analyzer.issues(document),
         {:ok, workflow} <- step(fn -> steps.build.(document) end),
         {:ok, json} <- step(fn -> steps.to_json.(workflow) end),
         {:ok, decoded} <- step(fn -> steps.from_json.(json) end),
         {:ok, bytes} <- step(fn -> steps.to_json.(decoded) end),
         {:ok, {root, decoded_root}} <- step(fn -> roots(workflow, decoded) end),
         [] <- mismatches(workflow == decoded, root == decoded_root, json == bytes) do
      {:valid, %{workflow: workflow, json: json, fingerprint: root}}
    else
      {:error, issues} -> {:invalid, issues}
      issues when is_list(issues) -> {:invalid, issues}
    end
  end

  @spec step(fun :: (-> term())) :: {:ok, term()} | {:error, [Issue.t()]}
  defp step(fun), do: CoreBridge.guarded(:workflow, fun)

  @spec roots(workflow :: Workflow.t(), decoded :: Workflow.t()) :: {String.t(), String.t()}
  defp roots(workflow, decoded) do
    {Definition.fingerprint(workflow).root, Definition.fingerprint(decoded).root}
  end

  @spec mismatches(struct? :: boolean(), root? :: boolean(), bytes? :: boolean()) :: [Issue.t()]
  defp mismatches(struct?, root?, bytes?) do
    for {false, part} <- [{struct?, "workflow"}, {root?, "fingerprint"}, {bytes?, "JSON"}] do
      %Issue{
        code: :round_trip_mismatch,
        target: :workflow,
        message: "The exported #{part} changed when read back."
      }
    end
  end
end
