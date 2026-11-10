defmodule DomovoyWeb.KeymapTest do
  use ExUnit.Case, async: true

  alias DomovoyWeb.Keymap
  alias DomovoyWeb.Keymap.Spec

  @path Path.expand("../../priv/keymap.json", __DIR__)

  defp keymap(scopes, prefixes \\ ["g"]),
    do: JSON.encode!(%{"prefixes" => prefixes, "scopes" => scopes})

  describe "Spec.parse!/1" do
    test "the real keymap parses and normalises single keys to lists" do
      keymap = @path |> File.read!() |> Spec.parse!()

      assert keymap.prefixes == ["g", "f"]
      assert keymap.scopes["page"]["go.workflows"] == ["g w"]
      assert keymap.scopes["page"]["app.hints"] == ["?"]
    end

    test "a valid fixture parses" do
      json = keymap(%{"page" => %{"go.home" => "g h", "row.pick" => ["1", "2"]}})

      assert Spec.parse!(json) == %{
               prefixes: ["g"],
               scopes: %{"page" => %{"go.home" => ["g h"], "row.pick" => ["1", "2"]}}
             }
    end

    test "rejects a scope other than page" do
      assert_raise ArgumentError, ~r/is not page/, fn ->
        Spec.parse!(keymap(%{"dialog" => %{"go.home" => "x"}}))
      end
    end

    test "rejects a malformed action id" do
      assert_raise ArgumentError, ~r/action ids look like/, fn ->
        Spec.parse!(keymap(%{"page" => %{"Stop" => "x"}}))
      end
    end

    test "rejects a key that is neither one character nor a sequence" do
      assert_raise ArgumentError, ~r/is not one printable character or/, fn ->
        Spec.parse!(keymap(%{"page" => %{"go.home" => "ab"}}))
      end
    end

    test "rejects a sequence with an undeclared prefix" do
      assert_raise ArgumentError, ~r/uses undeclared prefix/, fn ->
        Spec.parse!(keymap(%{"page" => %{"pr.new" => "n p"}}))
      end
    end

    test "rejects a single key that is a prefix" do
      assert_raise ArgumentError, ~r/is a prefix/, fn ->
        Spec.parse!(keymap(%{"page" => %{"go.home" => "g"}}))
      end
    end

    test "rejects two actions on one key" do
      assert_raise ArgumentError, ~r/is already bound/, fn ->
        Spec.parse!(keymap(%{"page" => %{"agent.stop" => "x", "agent.kill" => "x"}}))
      end
    end

    test "rejects an empty key list" do
      assert_raise ArgumentError, ~r/expected a key or a non-empty list/, fn ->
        Spec.parse!(keymap(%{"page" => %{"go.home" => []}}))
      end
    end

    test "rejects a top level that is not an object" do
      assert_raise ArgumentError, ~r/expected an object/, fn -> Spec.parse!("[]") end
    end

    test "rejects a prefix longer than one character" do
      assert_raise ArgumentError, ~r/is not one printable character$/, fn ->
        Spec.parse!(keymap(%{"page" => %{"go.home" => "h"}}, ["gg"]))
      end
    end

    test "rejects repeated prefixes" do
      assert_raise ArgumentError, ~r/prefixes repeat/, fn ->
        Spec.parse!(keymap(%{"page" => %{"go.home" => "g h"}}, ["g", "g"]))
      end
    end
  end

  describe "Keymap" do
    test "every action the app uses has a key" do
      for action <- ~w(go.dashboard go.projects go.jobs go.workflows app.hints),
          do: assert(is_binary(Keymap.key(action)))
    end

    test "attrs/1 renders data-shortcut and, for single keys, aria-keyshortcuts" do
      assert Keymap.attrs("go.jobs") == [{"data-shortcut", "g j"}]
      assert Keymap.attrs("app.hints") == [{"data-shortcut", "?"}, {"aria-keyshortcuts", "?"}]
      assert Keymap.attrs(nil) == []
    end

    test "key/2 and attrs/2 index into a list action" do
      assert Keymap.key("filter.pick", 1) == "f 2"
      assert Keymap.key("filter.pick", 6) == nil
      assert Keymap.attrs("filter.pick", 0) == [{"data-shortcut", "f 1"}]
      assert Keymap.attrs("filter.pick", 9) == []
      assert Keymap.attrs(nil, 0) == []
    end

    test "search.focus is the slash key" do
      assert Keymap.key("search.focus") == "/"
    end

    test "key/1 raises for an unknown action" do
      assert_raise ArgumentError, ~r/unknown keymap action/, fn -> Keymap.key("unknown.x") end
    end
  end
end
