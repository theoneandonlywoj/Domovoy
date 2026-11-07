defmodule Domovoy.SpyJournal do
  @moduledoc """
  The runtime's ETS Journal, reporting whether its reads ran inside a transaction of
  `Domovoy.Repo`. `:spy_journal` in the calling process's dictionary arms it:

    * `:report`: each `replay_root/2` and `read_after/4` sends the caller
      `{:in_transaction, boolean}`;
    * `{:insert, row}`: the same, and the first such read inserts `row` first, as a
      start running alongside would.
  """

  @behaviour DomovoyCore.Journal.Canonical

  alias Domovoy.Composer.Runs
  alias DomovoyCore.Journal.Canonical
  alias DomovoyCore.Journal.Canonical.ETS
  alias DomovoyCore.Runtime

  @doc """
  Opens the Journal of the host's runtime.
  """
  @spec open(opts :: keyword()) :: {:ok, ETS.handle()} | {:error, DomovoyCore.Error.t()}
  def open(_opts), do: ETS.open(Runtime.journal(Runs.runtime()))

  @impl Canonical
  def replay_root(handle, run_key) do
    spy()
    ETS.replay_root(handle, run_key)
  end

  @impl Canonical
  def read_after(handle, run_key, seq, opts) do
    spy()
    ETS.read_after(handle, run_key, seq, opts)
  end

  for {name, arity} <- Canonical.behaviour_info(:callbacks),
      name not in [:replay_root, :read_after] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl Canonical
    def unquote(name)(unquote_splicing(args)), do: ETS.unquote(name)(unquote_splicing(args))
  end

  @spec spy() :: :ok
  defp spy do
    case Process.get(:spy_journal) do
      nil ->
        :ok

      armed ->
        with {:insert, row} <- armed do
          Process.put(:spy_journal, :report)
          Domovoy.Repo.insert!(row, log: false)
        end

        send(self(), {:in_transaction, Domovoy.Repo.in_transaction?()})
        :ok
    end
  end
end
