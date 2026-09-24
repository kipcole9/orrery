defmodule Orrery.Projects do
  @moduledoc """
  Loads the project registry: which groups and repositories the dashboard
  covers.

  The registry is an Elixir map evaluated from a file, `priv/projects.exs` by
  default. Each group names a directory under the root; every git working tree
  inside it is picked up automatically, so adding a project means cloning it
  into the right place. A group may instead pin an explicit `:repos` list, and
  `:exclude` removes repositories by their path relative to the root.

  The file to read is `:projects_file` in the `:orrery` application
  environment, or the `ORRERY_PROJECTS` environment variable at runtime.
  """

  @type group :: %{
          required(:name) => String.t(),
          required(:dir) => String.t(),
          optional(:blurb) => String.t(),
          optional(:repos) => [String.t()]
        }

  @type registry :: %{
          required(:root) => String.t(),
          required(:groups) => [group()],
          optional(:exclude) => [String.t()]
        }

  @doc """
  Returns the path of the registry file.

  ### Returns

  * The configured `:projects_file`, or `priv/projects.exs` in the
    application's priv directory.

  """
  @spec file() :: Path.t()
  def file do
    Application.get_env(:orrery, :projects_file) ||
      Path.join(:code.priv_dir(:orrery), "projects.exs")
  end

  @doc """
  Loads and validates the registry.

  ### Arguments

  * `file` is the registry file to evaluate. Defaults to `file/0`.

  ### Returns

  * `{:ok, registry}` with the root expanded.

  * `{:error, {:missing_file, path}}` when the file does not exist.

  * `{:error, {:invalid, message}}` when the file does not evaluate to a
    registry map.

  ### Examples

      iex> {:error, {:missing_file, _}} = Orrery.Projects.load("/nowhere/projects.exs")

  """
  @spec load(Path.t() | nil) :: {:ok, registry()} | {:error, term()}
  def load(file \\ nil) do
    file = file || file()

    if File.regular?(file) do
      evaluate(file)
    else
      {:error, {:missing_file, file}}
    end
  end

  defp evaluate(file) do
    {value, _binding} = Code.eval_file(file)
    validate(value)
  rescue
    exception -> {:error, {:invalid, Exception.message(exception)}}
  end

  defp validate(%{root: root, groups: groups} = registry)
       when is_binary(root) and is_list(groups) do
    case Enum.reject(groups, &valid_group?/1) do
      [] ->
        {:ok,
         registry
         |> Map.put(:root, Path.expand(root))
         |> Map.put_new(:exclude, [])}

      [bad | _] ->
        {:error, {:invalid, "group without a :name and :dir: #{inspect(bad)}"}}
    end
  end

  defp validate(other) do
    {:error, {:invalid, "expected a map with :root and :groups, got #{inspect(other)}"}}
  end

  defp valid_group?(%{name: name, dir: dir}) when is_binary(name) and is_binary(dir), do: true
  defp valid_group?(_), do: false

  @doc """
  Restricts a registry to the named groups.

  Names are matched case-insensitively. An empty list leaves the registry
  unchanged.

  ### Arguments

  * `registry` is a registry returned by `load/1`.

  * `names` is a list of group names.

  ### Returns

  * `{:ok, registry}` containing only the matching groups.

  * `{:error, {:unknown_groups, names, known}}` when nothing matches.

  ### Examples

      iex> registry = %{root: "/tmp", groups: [%{name: "Tempo", dir: "tempo"}], exclude: []}
      iex> {:ok, %{groups: [%{name: "Tempo"}]}} = Orrery.Projects.only(registry, ["tempo"])
      iex> Orrery.Projects.only(registry, ["Nope"])
      {:error, {:unknown_groups, ["Nope"], ["Tempo"]}}

  """
  @spec only(registry(), [String.t()]) :: {:ok, registry()} | {:error, term()}
  def only(registry, []), do: {:ok, registry}

  def only(registry, names) when is_list(names) do
    wanted = Enum.map(names, &String.downcase/1)
    groups = Enum.filter(registry.groups, &(String.downcase(&1.name) in wanted))

    if groups == [] do
      {:error, {:unknown_groups, names, Enum.map(registry.groups, & &1.name)}}
    else
      {:ok, %{registry | groups: groups}}
    end
  end

  @doc """
  Describes a registry error in one line, for logs and the command line.

  ### Arguments

  * `reason` is the second element of an `{:error, reason}` tuple returned by
    this module.

  ### Returns

  * A string.

  ### Examples

      iex> Orrery.Projects.describe({:missing_file, "/x/projects.exs"})
      "registry file not found: /x/projects.exs"

  """
  @spec describe(term()) :: String.t()
  def describe({:missing_file, path}), do: "registry file not found: #{path}"
  def describe({:invalid, message}), do: "invalid registry: #{message}"

  def describe({:unknown_groups, names, known}),
    do: "no group matches #{Enum.join(names, ", ")}; known groups: #{Enum.join(known, ", ")}"

  def describe(other), do: inspect(other)
end
