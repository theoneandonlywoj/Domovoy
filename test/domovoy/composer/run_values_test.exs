defmodule Domovoy.Composer.RunValuesTest do
  use ExUnit.Case, async: true

  alias Domovoy.Composer.RunValues
  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Record
  alias DomovoyCore.Type
  alias DomovoyCore.Value

  @sentinel "sentinel-result-reason"

  defp value(type, raw), do: %Value{type: type, value: raw, metadata: %{}}

  defp record(status, result, metadata \\ %{}) do
    Record.new(%{
      job: Job.new("run"),
      node: "step",
      status: status,
      result: result,
      metadata: metadata
    })
  end

  describe "render_value/1" do
    test "a small value is its whole JSON text" do
      assert %{kind: :json, text: text, truncated?: false, bytes: bytes} =
               RunValues.render_value(Value.cast!(%{"price" => 1}, Type.Map))

      assert Jason.decode!(text) == %{"price" => 1}
      assert bytes == byte_size(text)
    end

    test "a value past the preview is cut on a UTF-8 boundary, with its full size" do
      # Two-byte characters after a one-byte quote, so the cut falls inside one.
      long = String.duplicate("ż", 20_000)

      assert %{kind: :json, text: text, truncated?: true, bytes: bytes} =
               RunValues.render_value(Value.cast!(long, Type.String))

      assert String.valid?(text)
      assert byte_size(text) <= RunValues.preview_bytes()
      assert byte_size(text) >= RunValues.preview_bytes() - 3
      assert bytes == byte_size(Jason.encode!(long, pretty: true))
    end

    test "a value of several MiB keeps only its preview" do
      huge = %{"rows" => List.duplicate("x", 1_000_000)}

      assert %{kind: :json, text: text, truncated?: true, bytes: bytes} =
               RunValues.render_value(Value.cast!(huge, Type.Map))

      assert byte_size(text) <= RunValues.preview_bytes()
      assert bytes > 4_000_000
    end

    test "binary output gives its size and never its base64" do
      bytes = <<0, 255, 1, 2>> <> String.duplicate("a", 100)

      assert RunValues.render_value(Value.cast!(bytes, Type.Binary)) ==
               %{kind: :binary, bytes: byte_size(bytes)}
    end

    test "bytes that aren't UTF-8 are never shown" do
      for raw <- [<<0xFF>>, %{"a" => <<0xFF, 0xFE>>}],
          type <- [Type.Any, Type.Map, Type.String] do
        rendered = RunValues.render_value(value(type, raw))
        assert rendered.kind in [:bytes, :type]
        refute Map.has_key?(rendered, :text)
      end
    end

    test "an unknown struct, and a value its type refuses to dump, give the type name" do
      assert RunValues.render_value(value(Type.Any, MapSet.new([1]))) ==
               %{kind: :type, type: "DomovoyCore.Type.Any"}

      assert RunValues.render_value(value(Type.Any, self())) ==
               %{kind: :type, type: "DomovoyCore.Type.Any"}
    end
  end

  describe "render_record/1" do
    test "an ok record renders its value, with the runner's version" do
      runner = %{"runner" => %{"module" => "Elixir.Step", "version" => "1.2.0"}}

      assert %{status: :ok, output: %{kind: :json}, version: "1.2.0"} =
               RunValues.render_record(record(:ok, Value.cast!(42, Type.Integer), runner))

      assert %{version: nil} = RunValues.render_record(record(:ok, Value.cast!(1, Type.Integer)))
    end

    test "an error gives its type, its retryability and host text, never its reason" do
      for retryable? <- [true, false] do
        error = %Error{
          type: :leak_failed,
          reason: %{"secret" => @sentinel},
          retryable?: retryable?
        }

        rendered = RunValues.render_record(record(:error, error))

        assert %{status: :error, type: "leak_failed", retryable?: ^retryable?, text: text} =
                 rendered

        assert text =~ if(retryable?, do: "may help", else: "won't help")
        refute inspect(rendered) =~ @sentinel
      end
    end

    test "canonical_too_large says a retry won't help" do
      error = %Error{type: :canonical_too_large, reason: %{size: 2, limit: 1}, retryable?: true}

      assert %{status: :error, type: "canonical_too_large", retryable?: false, text: text} =
               RunValues.render_record(record(:error, error))

      assert text =~ "too large to keep"
      assert text =~ "Retrying won't help"
    end

    test "cancelled and skipped records give their status" do
      assert %{status: :cancelled} = RunValues.render_record(record(:cancelled, nil))
      assert %{status: :skipped} = RunValues.render_record(record(:skipped, nil))
    end

    test "a record whose result no longer loads could not be loaded" do
      {:ok, document} = Record.dump(record(:ok, Value.cast!(42, Type.Integer)))
      document = put_in(document, ["result", "type"], "Elixir.Gone.Type")
      {:ok, degraded} = Record.load(document)

      assert %{status: :degraded} = RunValues.render_record(degraded)
    end
  end
end
