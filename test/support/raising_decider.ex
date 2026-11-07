defmodule Domovoy.RaisingDecider do
  @moduledoc """
  Tells the test's gate it ran, then raises with the committed value of the node
  that the `:node` option names. It isn't curated, so only a hand-built Core
  workflow can name it.
  """

  use DomovoyCore.Decider, effect: :pure

  alias DomovoyCore.Context
  alias DomovoyCore.Decision
  alias DomovoyCore.Value

  @impl DomovoyCore.Decider
  def decide(%Decision{name: name}, %Context{} = context, opts) do
    send(Domovoy.RunTestGate, {:decided, name})
    {:ok, %Value{value: secret}} = Context.read(context, Keyword.fetch!(opts, :node))
    raise ArgumentError, secret
  end
end
