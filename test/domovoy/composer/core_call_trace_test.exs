defmodule Domovoy.CoreCallTraceTest do
  # RunCase is never async, which the all-process trace needs.
  use Domovoy.RunCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.CoreCallTrace
  alias Domovoy.Examples.Definitions

  test "a real cancel of an open run is recorded with its arguments" do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document

    {:ok, values} =
      RunInputs.parse(document, %{
        "rooms" => "3",
        "bathrooms" => "1",
        "area" => "58.5",
        "district" => "Krowodrza"
      })

    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    handle = open!(run_id)
    await_phase(handle, "waiting")

    calls =
      CoreCallTrace.calls(fn ->
        assert {:ok, %{operation_id: _id}} = Composer.cancel_run(handle, "cancel-intent")
      end)

    assert [^handle, :cancel, opts] =
             Enum.find_value(calls, fn
               {:command, args} -> args
               _other -> nil
             end)

    assert opts[:command_id] == "cancel-intent"
  end

  test "nothing is recorded when nothing calls Core" do
    assert CoreCallTrace.calls(fn -> :ok end) == []
  end
end
