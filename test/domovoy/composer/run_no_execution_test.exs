defmodule Domovoy.Composer.RunNoExecutionTest do
  use Domovoy.RunCase

  import Domovoy.ComposerFixtures, only: [draft!: 2]

  alias Domovoy.Composer
  alias Domovoy.Composer.Export
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Examples.Cracow
  alias Domovoy.Examples.Definitions
  alias Domovoy.NoExecutionTrace

  @form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza",
    "floor" => "2",
    "balcony" => "true",
    "year_built" => "1995"
  }

  defp finished_run(draft, values) do
    assert {:ok, run_id} = Runs.start(start_attrs(draft, values))
    assert %{outcome: "succeeded"} = await_phase(open!(run_id), "finished")
    run_id
  end

  defp prices_draft do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price")).document
    {:ok, values} = RunInputs.parse(document, @form)
    {draft!(document, "Prices"), values}
  end

  test "a real start under the trace records its runner calls, so a silent trace can't pass" do
    {draft, values} = prices_draft()

    report = NoExecutionTrace.run(fn -> finished_run(draft, values) end)

    assert is_binary(report.result)
    calls = Enum.map(report.forbidden_calls, &elem(&1, 1))

    assert {Cracow.Normalize, :run, 2} in calls
    assert {Cracow.Estimate, :run, 2} in calls
  end

  test "validating and exporting a draft with a finished run stays clean" do
    {draft, values} = prices_draft()
    finished_run(draft, values)
    {:ok, reread} = Composer.get_draft(draft.id)

    report =
      NoExecutionTrace.run(fn ->
        {Composer.validate(reread.document), Export.validate(reread.document)}
      end)

    assert {{:valid, %{json: json}}, {:valid, %{json: json}}} = report.result
    assert Enum.all?(report.controls_expected, &(&1 in report.control_calls))
    assert report.forbidden_calls == []
  end

  test "reading a finished run from its row executes nothing" do
    {draft, values} = prices_draft()
    run_id = finished_run(draft, values)

    report =
      NoExecutionTrace.run(fn ->
        {:ok, row} = Composer.get_run(draft.id, run_id)
        {:ok, %{handle: handle}} = Composer.open_run(row)
        Composer.run_view(handle)
      end)

    assert {:ok, %{committed_phase: "finished"}} = report.result
    assert report.forbidden_calls == []
  end
end
