defmodule Domovoy.UncertainLeakRunner do
  @moduledoc """
  Raises with its `secret` input, and declares no effect, so Core treats the crashed
  attempt as non-idempotent. It takes `Domovoy.LeakRunner`'s `mode` and ignores it,
  so one fixture serves both.
  """

  use DomovoyCore.Runner

  alias DomovoyCore.Type

  input do
    field(:secret, Type.String)
    field(:mode, Type.String)
  end

  required([:secret])
  output(Type.String)

  @impl DomovoyCore.Runner
  def run(%Input{secret: secret}, _context), do: raise(ArgumentError, secret)
end
