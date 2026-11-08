defmodule Domovoy.Composer.RunValues do
  @moduledoc """
  A node's stored result as the run sidebar shows it, bounded and safe to render.

  Pure, and never inspects a value: an output becomes JSON text cut to a preview, a
  byte size or a type name, and an error becomes its type, whether a retry can help
  and text written here. An error's `reason` and its message are never read, since
  either can hold an input's value or an expanded path.
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Record
  alias DomovoyCore.Type.Binary
  alias DomovoyCore.Value

  @preview_bytes 16_384

  @type output ::
          %{kind: :json, text: String.t(), bytes: non_neg_integer(), truncated?: boolean()}
          | %{kind: :binary, bytes: non_neg_integer()}
          | %{kind: :bytes, bytes: non_neg_integer()}
          | %{kind: :type, type: String.t()}

  @type rendered ::
          %{status: :ok, output: output(), version: String.t() | nil}
          | %{
              status: :error,
              type: String.t(),
              retryable?: boolean(),
              text: String.t(),
              version: String.t() | nil
            }
          | %{status: :cancelled | :skipped | :degraded, version: String.t() | nil}

  @doc """
  The most of a preview, in bytes.
  """
  @spec preview_bytes() :: pos_integer()
  def preview_bytes, do: @preview_bytes

  @doc """
  An output as JSON text, cut on a UTF-8 boundary past `preview_bytes/0`. Binary
  output gives its size and no content, because its dump is base64 text that would
  pass as JSON. Bytes that aren't UTF-8 give their size, and a value that can't be
  dumped or encoded gives its type's name.
  """
  @spec render_value(value :: Value.t()) :: output()
  def render_value(%Value{type: Binary, value: bytes}) when is_binary(bytes),
    do: %{kind: :binary, bytes: byte_size(bytes)}

  def render_value(%Value{type: type} = value) do
    case Value.dump(value) do
      {:ok, %{"value" => dumped}} -> encode(dumped, type)
      {:error, _refused} -> type_only(type)
    end
  end

  @doc """
  A record as the sidebar shows it, with the runner version its runner block names.
  """
  @spec render_record(record :: Record.t()) :: rendered()
  def render_record(%Record{} = record) do
    {_module, version} = Record.stored_runner(record)

    record
    |> rendered()
    |> Map.put(:version, version)
  end

  @spec rendered(record :: Record.t()) :: map()
  defp rendered(%Record{} = record) do
    cond do
      Record.degraded?(record) -> %{status: :degraded}
      record.status == :ok -> %{status: :ok, output: render_value(record.result)}
      record.status == :error -> failure(record.result)
      true -> %{status: record.status}
    end
  end

  @spec failure(error :: term()) :: map()
  defp failure(%Error{type: :canonical_too_large}) do
    %{
      status: :error,
      type: "canonical_too_large",
      retryable?: false,
      text: "This step's output was too large to keep, so the run failed. Retrying won't help."
    }
  end

  defp failure(%Error{type: type, retryable?: retryable?}) when is_atom(type) do
    %{
      status: :error,
      type: Atom.to_string(type),
      retryable?: retryable? == true,
      text:
        if(retryable? == true,
          do: "This step failed. A retry may help.",
          else: "This step failed. Retrying won't help."
        )
    }
  end

  defp failure(_unknown),
    do: %{status: :error, type: "unknown_error", retryable?: false, text: "This step failed."}

  @spec encode(dumped :: term(), type :: module()) :: output()
  defp encode(dumped, type) do
    case Jason.encode(dumped, pretty: true) do
      {:ok, text} -> preview(text)
      {:error, _invalid} when is_binary(dumped) -> %{kind: :bytes, bytes: byte_size(dumped)}
      {:error, _invalid} -> type_only(type)
    end
  rescue
    Protocol.UndefinedError -> type_only(type)
  end

  @spec preview(text :: String.t()) :: output()
  defp preview(text) when byte_size(text) <= @preview_bytes,
    do: %{kind: :json, text: text, bytes: byte_size(text), truncated?: false}

  defp preview(text) do
    cut = utf8_prefix(binary_part(text, 0, @preview_bytes))
    %{kind: :json, text: cut, bytes: byte_size(text), truncated?: true}
  end

  # A cut can split one character, of at most four bytes.
  @spec utf8_prefix(bytes :: binary()) :: String.t()
  defp utf8_prefix(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: utf8_prefix(binary_part(bytes, 0, byte_size(bytes) - 1))
  end

  @spec type_only(type :: term()) :: output()
  defp type_only(type) when is_atom(type),
    do: %{kind: :type, type: type |> Atom.to_string() |> String.replace_prefix("Elixir.", "")}

  defp type_only(_type), do: %{kind: :type, type: "unknown"}
end
