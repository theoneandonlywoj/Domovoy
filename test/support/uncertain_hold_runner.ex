defmodule Domovoy.UncertainHoldRunner do
  @moduledoc """
  `Domovoy.PureHoldRunner` with no declared effect, so an interrupted attempt leaves
  its outcome unknown.
  """

  use DomovoyCore.Runner

  alias Domovoy.PureHoldRunner
  alias DomovoyCore.Type

  input do
    field(:trap_exit, Type.Boolean, default: false)
  end

  output(Type.String)

  @impl DomovoyCore.Runner
  def run(%Input{trap_exit: trap_exit}, %DomovoyCore.Context{node: node}),
    do: PureHoldRunner.hold(node, trap_exit)
end
