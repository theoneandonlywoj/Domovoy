defmodule Domovoy.LeakRunner do
  @moduledoc """
  Gives back, fails with, raises, exits with or throws its `secret` input, as `mode`
  says, so a test can look for that value in the logs of each path.
  """

  use DomovoyCore.Runner, effect: :pure

  alias DomovoyCore.Error
  alias DomovoyCore.Type

  input do
    field(:secret, Type.String)
    field(:mode, Type.String)
  end

  required([:secret, :mode])
  output(Type.String)

  @impl DomovoyCore.Runner
  def run(%Input{mode: "succeed", secret: secret}, _context), do: {:ok, secret}

  def run(%Input{mode: "fail", secret: secret}, _context) do
    {:error, Error.new(%{type: :leak_failed, reason: %{"secret" => secret}, retryable?: false})}
  end

  def run(%Input{mode: "raise", secret: secret}, _context), do: raise(ArgumentError, secret)
  def run(%Input{mode: "exit", secret: secret}, _context), do: exit(secret)
  def run(%Input{mode: "throw", secret: secret}, _context), do: throw(secret)
end
