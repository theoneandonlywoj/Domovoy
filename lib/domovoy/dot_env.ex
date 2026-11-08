defmodule Domovoy.DotEnv do
  @moduledoc """
  Reads literal local Postgres configuration without changing the process environment.

  A checkout's `.env` wins over its main Git worktree's file. Present environment
  keys override file values, including empty values. Only a wholly unconfigured
  test environment receives the CI defaults.
  """

  @keys ~w(POSTGRES_PASSWORD POSTGRES_PORT)

  @spec postgres(Path.t(), atom(), map()) :: {:ok, keyword()} | {:error, String.t()}
  def postgres(root, config_env, env_map \\ System.get_env()) do
    with {:ok, file} <- selected_file(Path.expand(root)),
         {:ok, values} <- read_values(file) do
      if config_env == :test and is_nil(file) and
           Enum.all?(@keys, &(not Map.has_key?(env_map, &1))) do
        {:ok, password: "postgres", port: 5432}
      else
        values = Map.merge(values, Map.take(env_map, @keys))
        validate(values)
      end
    end
  end

  defp selected_file(root) do
    case File.lstat(Path.join(root, ".env")) do
      {:ok, _} -> {:ok, Path.join(root, ".env")}
      {:error, :enoent} -> main_file(root)
      {:error, _} -> {:error, ".env is unreadable; see .env.example"}
    end
  end

  defp main_file(root) do
    git = Path.join(root, ".git")

    case File.lstat(git) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, nil}
      {:error, :enoent} -> {:ok, nil}
      {:ok, %File.Stat{type: :regular}} -> worktree_file(root, git)
      _ -> metadata_error()
    end
  end

  defp worktree_file(root, git) do
    with {:ok, pointer} <- File.read(git),
         [_, gitdir] <- Regex.run(~r/\Agitdir: ([^\r\n]+)\r?\n?\z/, pointer),
         gitdir = Path.expand(gitdir, root),
         {:ok, common} <- File.read(Path.join(gitdir, "commondir")),
         common = String.trim(common),
         true <- common != "" and not String.contains?(common, ["\n", "\r", <<0>>]),
         common = Path.expand(common, gitdir),
         true <- File.dir?(common),
         true <- Path.basename(common) == ".git" do
      path = Path.join(Path.dirname(common), ".env")

      case File.lstat(path) do
        {:error, :enoent} -> {:ok, nil}
        {:ok, _} -> {:ok, path}
        _ -> {:error, ".env is unreadable; see .env.example"}
      end
    else
      _ -> metadata_error()
    end
  end

  defp metadata_error, do: {:error, ".env discovery failed: invalid Git worktree metadata"}

  defp read_values(nil), do: {:ok, %{}}

  defp read_values(file) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(file),
         true <- Bitwise.band(mode, 0o444) != 0,
         {:ok, text} <- File.read(file),
         true <- String.valid?(text) do
      text
      |> String.split("\n")
      |> Enum.reduce_while({:ok, %{}}, &parse_line/2)
    else
      {:ok, %File.Stat{type: type}} when type != :regular ->
        {:error, ".env must be a regular file; see .env.example"}

      _ ->
        {:error, ".env is unreadable; see .env.example"}
    end
  end

  defp parse_line(line, {:ok, values}) do
    line = String.trim(line)

    if line == "" or String.starts_with?(line, "#") do
      {:cont, {:ok, values}}
    else
      case Regex.run(~r/\A(?:export[\t ]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/, line) do
        [_, key, value] -> parse_value(key, value, values)
        _ -> {:halt, syntax_error()}
      end
    end
  end

  defp parse_value(key, value, values) do
    parsed = literal_value(value)

    case parsed do
      {:ok, literal} ->
        if String.contains?(literal, ["$", "`", <<0>>, "\r"]) do
          {:halt, syntax_error()}
        else
          {:cont, {:ok, Map.put(values, key, literal)}}
        end

      :error ->
        {:halt, syntax_error()}
    end
  end

  defp literal_value(<<quote, _rest::binary>> = value) when quote in [?', ?"] do
    pattern =
      if quote == ?', do: ~r/\A'([^']*)'(?:[\t ]+#.*)?\z/, else: ~r/\A"([^"]*)"(?:[\t ]+#.*)?\z/

    case Regex.run(pattern, value) do
      [_, literal] -> {:ok, literal}
      _ -> :error
    end
  end

  defp literal_value(value) do
    literal = Regex.replace(~r/[\t ]+#.*\z/, value, "") |> String.trim_trailing()

    if String.contains?(literal, [" ", "\t", "'", "\"", "\\"]),
      do: :error,
      else: {:ok, literal}
  end

  defp syntax_error, do: {:error, ".env has unsupported literal syntax; see .env.example"}

  defp validate(values) do
    invalid =
      Enum.filter(@keys, fn
        "POSTGRES_PASSWORD" -> not valid_password?(values["POSTGRES_PASSWORD"])
        "POSTGRES_PORT" -> not valid_port?(values["POSTGRES_PORT"])
      end)

    case invalid do
      [] ->
        {:ok,
         password: values["POSTGRES_PASSWORD"], port: String.to_integer(values["POSTGRES_PORT"])}

      keys ->
        {:error,
         "Missing or invalid #{Enum.join(keys, ", ")} in environment or .env; see .env.example"}
    end
  end

  defp valid_password?(value) when is_binary(value) do
    Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value) and
      not String.starts_with?(String.downcase(value), ["replace", "change", "your-"]) and
      String.downcase(value) not in ["postgres", "password", "secret", "placeholder"]
  end

  defp valid_password?(_), do: false

  defp valid_port?(value) when is_binary(value) do
    Regex.match?(~r/\A[0-9]+\z/, value) and
      case Integer.parse(value) do
        {port, ""} -> port in 1..65_535 and port != 5432
        _ -> false
      end
  end

  defp valid_port?(_), do: false
end
