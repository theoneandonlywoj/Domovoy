defmodule Domovoy.UnknownCommitJournal do
  @moduledoc """
  The runtime's ETS Journal, except that a start's acknowledgement is lost, which a
  host build can't otherwise produce: Core's failpoints compile to nothing outside its
  own tests. `:unknown_commit` in the calling process's dictionary says how, and each
  attempt sends the caller `:start_attempt`:

    * `:never_landed`, the default: nothing commits;
    * `:landed`: the commit lands, and the first acknowledgement is lost.
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
  def start(handle, start_key, commit, opts) do
    send(self(), :start_attempt)
    attempt = Process.get(:unknown_commit_attempt, 1)
    Process.put(:unknown_commit_attempt, attempt + 1)

    case {Process.get(:unknown_commit, :never_landed), attempt} do
      {:never_landed, _attempt} ->
        {:error, Canonical.outcome_unknown(__MODULE__, :start, %{cause: :lost})}

      {:landed, 1} ->
        {:ok, _started} = ETS.start(handle, start_key, commit, opts)
        {:error, Canonical.outcome_unknown(__MODULE__, :start, %{cause: :lost})}

      {:landed, _retry} ->
        ETS.start(handle, start_key, commit, opts)
    end
  end

  for {name, arity} <- Canonical.behaviour_info(:callbacks), name != :start do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl Canonical
    def unquote(name)(unquote_splicing(args)), do: ETS.unquote(name)(unquote_splicing(args))
  end
end
