defmodule Domovoy.DotEnvTest do
  use ExUnit.Case, async: true

  alias Domovoy.DotEnv

  @password "test_private_123"
  @valid %{"POSTGRES_PASSWORD" => @password, "POSTGRES_PORT" => "54321"}

  setup do
    prefix = "domovoy-dotenv-"
    root = Path.join(System.tmp_dir!(), "#{prefix}#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp put(root, contents), do: File.write!(Path.join(root, ".env"), contents)
  defp valid_file, do: "POSTGRES_PASSWORD=#{@password}\nPOSTGRES_PORT=54321\n"

  defp worktree(root, relative? \\ false) do
    main = Path.join(root, "main")
    child = Path.join(root, "child")
    metadata = Path.join(main, ".git/worktrees/child")
    File.mkdir_p!(metadata)
    File.mkdir_p!(child)
    pointer = if relative?, do: "../main/.git/worktrees/child", else: metadata
    File.write!(Path.join(child, ".git"), "gitdir: #{pointer}\n")
    File.write!(Path.join(metadata, "commondir"), "../..\n")
    {main, child}
  end

  test "wholly absent test configuration alone receives CI defaults", %{root: root} do
    assert DotEnv.postgres(root, :test, %{}) == {:ok, password: "postgres", port: 5432}
    File.mkdir!(Path.join(root, ".git"))
    assert DotEnv.postgres(root, :test, %{}) == {:ok, password: "postgres", port: 5432}
    assert {:error, message} = DotEnv.postgres(root, :dev, %{})
    assert message =~ "POSTGRES_PASSWORD, POSTGRES_PORT"
  end

  test "main fallback resolves absolute and relative worktree pointers", %{root: root} do
    for relative? <- [false, true] do
      fixture = Path.join(root, to_string(relative?))
      {main, child} = worktree(fixture, relative?)
      put(main, valid_file())
      assert DotEnv.postgres(child, :test, %{}) == {:ok, password: @password, port: 54_321}
      put(child, "POSTGRES_PASSWORD=own_private\nPOSTGRES_PORT=54322")
      assert DotEnv.postgres(child, :dev, %{}) == {:ok, password: "own_private", port: 54_322}
      put(child, "")
      assert {:error, _} = DotEnv.postgres(child, :test, %{})
    end
  end

  test "a selected empty, nonregular or unreadable file never falls back", %{root: root} do
    path = Path.join(root, ".env")
    put(root, "")
    assert {:error, message} = DotEnv.postgres(root, :test, %{})
    assert message =~ "POSTGRES_PASSWORD, POSTGRES_PORT"
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, message} = DotEnv.postgres(root, :test, @valid)
    assert message =~ "regular file"
    File.rmdir!(path)
    put(root, valid_file())
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)
    assert {:error, message} = DotEnv.postgres(root, :test, @valid)
    assert message =~ "unreadable"
    # Permission bits are part of the reader's explicit contract, including root runners.
    assert Bitwise.band(File.stat!(path).mode, 0o444) == 0
    File.chmod!(path, 0o600)
  end

  test "broken metadata cannot turn into CI fallback", %{root: root} do
    for pointer <- ["invalid", "gitdir: missing\n", "gitdir: \n"] do
      File.write!(Path.join(root, ".git"), pointer)
      assert {:error, message} = DotEnv.postgres(root, :test, %{})
      assert message =~ "metadata"
    end

    {main, child} = worktree(Path.join(root, "worktree"))
    File.write!(Path.join(main, ".git/worktrees/child/commondir"), "missing")
    assert {:error, _} = DotEnv.postgres(child, :test, %{})
  end

  test "supported literals, quotes, comments, CRLF and last duplicate", %{root: root} do
    put(
      root,
      """
      # comment
      export POSTGRES_PASSWORD='old_value'
      UNRELATED="literal with # interior"
      POSTGRES_PASSWORD="#{@password}" # comment
      POSTGRES_PORT=12345
      POSTGRES_PORT=54321 # chosen
      """
      |> String.replace("\n", "\r\n")
    )

    assert DotEnv.postgres(root, :dev, %{}) == {:ok, password: @password, port: 54_321}
  end

  test "unsupported syntax has sanitized diagnostics", %{root: root} do
    for line <- [
          "source secret-payload",
          "POSTGRES_PASSWORD=$(secret-payload)",
          "POSTGRES_PASSWORD=${secret-payload}",
          "POSTGRES_PASSWORD=`secret-payload`",
          "POSTGRES_PASSWORD='secret-payload",
          "POSTGRES_PASSWORD=secret payload",
          "POSTGRES_PASSWORD='secret'payload'",
          "POSTGRES_PASSWORD=a\\b",
          "POSTGRES_PASSWORD=secret\0payload"
        ] do
      put(root, line)
      assert {:error, message} = DotEnv.postgres(root, :test, @valid)
      assert message =~ "syntax"
      refute message =~ "secret-payload"
      refute message =~ @password
    end
  end

  test "caller key presence overrides the file, including empty", %{root: root} do
    put(root, valid_file())

    assert DotEnv.postgres(root, :test, %{"POSTGRES_PORT" => "54322"}) ==
             {:ok, password: @password, port: 54_322}

    for key <- Map.keys(@valid) do
      assert {:error, message} = DotEnv.postgres(root, :test, %{key => ""})
      assert message =~ key
    end
  end

  test "every dev/test partial presence combination fails", %{root: root} do
    for mode <- [:dev, :test],
        file <- [nil, "", "POSTGRES_PASSWORD=#{@password}", "POSTGRES_PORT=54321"],
        env <- [%{}, %{"POSTGRES_PASSWORD" => @password}, %{"POSTGRES_PORT" => "54321"}] do
      File.rm(Path.join(root, ".env"))
      if file, do: put(root, file)

      merged =
        Map.merge(
          if(file,
            do: Map.new(Regex.scan(~r/(POSTGRES_\w+)=(\w+)/, file), fn [_, k, v] -> {k, v} end),
            else: %{}
          ),
          env
        )

      result = DotEnv.postgres(root, mode, env)

      if map_size(merged) == 2 or (mode == :test and is_nil(file) and env == %{}),
        do: assert({:ok, _} = result),
        else: assert({:error, _} = result)
    end
  end

  test "local ports and placeholder passwords are validated without revealing values", %{
    root: root
  } do
    for port <- ["", "0", "65536", "5432", "-1", "+123", "1.0", "abc", "123 ", "1\n"] do
      assert {:error, message} = DotEnv.postgres(root, :test, %{@valid | "POSTGRES_PORT" => port})
      assert message =~ "POSTGRES_PORT"
      refute message =~ "POSTGRES_PASSWORD"
    end

    for port <- ["1", "65535", "054321"] do
      assert {:ok, _} = DotEnv.postgres(root, :dev, %{@valid | "POSTGRES_PORT" => port})
    end

    for password <- [
          "",
          "postgres",
          "password",
          "replace-with-password",
          "secret",
          "bad space",
          "bad:colon"
        ] do
      assert {:error, message} =
               DotEnv.postgres(root, :dev, %{@valid | "POSTGRES_PASSWORD" => password})

      assert message =~ "POSTGRES_PASSWORD"
      refute message =~ "POSTGRES_PORT"
      refute message =~ @password
    end
  end
end
