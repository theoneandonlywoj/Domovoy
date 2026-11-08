defmodule Domovoy.PureHoldRunner do
  @moduledoc """
  Holds a run open: tells the test's gate it has entered, then waits for `:release`.
  With `trap_exit` it outlives a stop's exit signal, which holds a `stopping` window
  open. A test-only runner, reaching the catalog through the Examples plugin's app.
  """

  use DomovoyCore.Runner, effect: :pure

  alias DomovoyCore.Type

  input do
    field(:trap_exit, Type.Boolean, default: false)
  end

  output(Type.String)

  @impl DomovoyCore.Runner
  def run(%Input{trap_exit: trap_exit}, %DomovoyCore.Context{node: node}),
    do: hold(node, trap_exit)

  @doc """
  The hold itself, which `Domovoy.UncertainHoldRunner` shares.
  """
  @spec hold(node :: String.t(), trap_exit :: boolean()) :: {:ok, String.t()}
  def hold(node, trap_exit) do
    Process.flag(:trap_exit, trap_exit)
    send(Domovoy.RunTestGate, {:entered, node, self()})

    receive do
      :release -> {:ok, "released"}
    end
  end
end
