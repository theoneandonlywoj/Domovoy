defmodule Domovoy.Composer.NoExecutionTest do
  # Not async: tracing covers every process in the VM.
  use ExUnit.Case, async: false

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Export
  alias Domovoy.NoExecutionTrace
  alias DomovoyCore.Decider
  alias DomovoyCore.Type

  @typed_inputs [
    {:put_input, "a_file", %{"type" => "DomovoyCore.Type.File", "default" => "~/a"}},
    {:put_input, "a_directory", %{"type" => "DomovoyCore.Type.Directory", "default" => "~/d"}},
    {:put_input, "a_path", %{"type" => "DomovoyCore.Type.Path", "default" => "~/p"}},
    {:put_input, "a_date", %{"type" => "DomovoyCore.Type.Date"}},
    {:put_input, "a_uuid",
     %{"type" => "DomovoyCore.Type.UUID", "default" => "018f4e3a-7b1c-4d2e-8f3a-9c0d1e2f3a4b"}},
    {:put_input, "a_uri",
     %{"type" => "DomovoyCore.Type.URI", "default" => "https://example.com"}},
    {:put_input, "an_email", %{"type" => "DomovoyCore.Type.Email", "default" => "a@example.com"}},
    {:add_node, "prepare", "DomovoyCore.Runner.WriteFile", "write"},
    {:set_literal, "prepare", "write", "path", "~/x", replace_binding: false}
  ]

  test "the trace watches what it must, and not the casts that are allowed" do
    targets = NoExecutionTrace.targets()

    for type <- [Type.File, Type.Directory, Type.Path, Type.Date, Type.String] do
      assert {type, :cast, 2} in targets
    end

    for type <- [Type.UUID, Type.URI, Type.Email] do
      refute {type, :cast, 2} in targets
    end

    assert {Decider.Person, :decide, 3} in targets
    assert {DomovoyMisePlugin.Runner.Trust, :run, 2} in targets
    assert {DomovoyClaudeCodePlugin.Runner.AskClaude, :run, 2} in targets
    assert {DomovoyGitPlugin.Validator.RemotePresent, :validate, 2} in targets
    assert {DomovoyClaudeCodePlugin.Reflect.Runner.CollectTranscripts, :run, 2} in targets
  end

  test "a call from the subject is caught, so a silent trace can't pass" do
    report =
      NoExecutionTrace.run(fn ->
        Decider.Person.decide(:junk, :junk, :junk)
        Task.await(Task.async(fn -> Type.Date.cast(:junk, %{}) end))
      end)

    assert {_pid, {Decider.Person, :decide, 3}} =
             Enum.find(report.forbidden_calls, &match?({_pid, {Decider.Person, _f, _a}}, &1))

    assert Enum.any?(report.forbidden_calls, &match?({_pid, {Type.Date, :cast, 2}}, &1))
  end

  test "validating and exporting scenario A calls nothing forbidden" do
    report = NoExecutionTrace.run(fn -> Export.validate(scenario_a()) end)

    assert {:valid, %{json: json}} = report.result
    assert is_binary(json)
    assert_clean(report)
  end

  test "validating file, directory, path and date inputs casts none of them" do
    report =
      NoExecutionTrace.run(fn ->
        scenario_a() |> edit_all(@typed_inputs) |> Export.validate()
      end)

    assert {:valid, _result} = report.result
    assert_clean(report)
  end

  test "an invalid document and a direct build call nothing forbidden" do
    report =
      NoExecutionTrace.run(fn ->
        incomplete = edit_all(scenario_a(), [{:clear_input, "prepare", "ask_claude", "context"}])
        {Export.validate(incomplete), CoreBridge.build(incomplete)}
      end)

    assert {{:invalid, [_ | _]}, {:error, [_ | _]}} = report.result
    assert_clean(report)
  end

  defp assert_clean(report) do
    assert report.traced != []

    for control <- report.controls_expected do
      assert control in report.control_calls, "control #{inspect(control)} was not traced"
    end

    assert report.forbidden_calls == []
  end
end
