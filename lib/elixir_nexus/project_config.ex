defmodule ElixirNexus.ProjectConfig do
  @moduledoc """
  Optional per-project configuration from a `.nexus.toml` file at the project root.

  Derive-first: when the file is absent (or unparseable), every field is empty and Nexus
  falls back to convention-based inference. Present keys override the derived behavior.

  Currently consumed: `entry_points.include` — globs whose matched files are treated as
  framework/DI entry points and excluded from `find_dead_code` (route handlers, sitemap,
  wired adapters that have no in-repo caller). `layers` is parsed and stored for the
  upcoming layer-derivation work but not yet acted on.

  ```toml
  [entry_points]
  include = ["app/**/route.ts", "app/sitemap.ts", "app/manifest.ts"]

  [layers]
  ports = "core/ports/**"
  adapters = "infrastructure/**"
  ```
  """

  defstruct entry_points: [], layers: %{}

  @type t :: %__MODULE__{entry_points: [String.t()], layers: map()}

  @app :elixir_nexus
  @env_key :project_config

  @doc """
  Load `.nexus.toml` from `project_root` and cache it (alongside the root, for
  relative-path glob matching) in Application env. Called at reindex time.
  """
  def load_and_store(project_root) do
    cfg = load(project_root)
    Application.put_env(@app, @env_key, {project_root, cfg})
    cfg
  end

  @doc "The cached `{project_root, config}` set by the last reindex, or `{nil, empty}`."
  def current do
    Application.get_env(@app, @env_key, {nil, %__MODULE__{}})
  end

  @doc "Read and parse `.nexus.toml` from a directory; empty struct if missing/invalid."
  def load(project_root) do
    path = Path.join(project_root, ".nexus.toml")

    case File.read(path) do
      {:ok, content} -> parse(content)
      _ -> %__MODULE__{}
    end
  end

  @doc "Parse `.nexus.toml` content into a config struct. Never raises."
  def parse(content) when is_binary(content) do
    case Toml.decode(content) do
      {:ok, map} -> from_map(map)
      {:error, _} -> %__MODULE__{}
    end
  end

  defp from_map(map) when is_map(map) do
    %__MODULE__{
      entry_points:
        map
        |> get_in(["entry_points", "include"])
        |> List.wrap()
        |> Enum.filter(&is_binary/1),
      layers: Map.get(map, "layers", %{})
    }
  end

  @doc """
  Resolve the architectural layer for a project-root-relative path. A `[layers]` entry whose
  glob matches wins (config override); otherwise fall back to convention-based derivation.
  """
  def layer_for(%__MODULE__{layers: layers}, path) when is_binary(path) do
    configured =
      Enum.find_value(layers, fn {layer, glob} ->
        if is_binary(glob) and glob_match?(glob, path), do: layer
      end)

    configured || ElixirNexus.Layers.classify(path)
  end

  def layer_for(_, path), do: ElixirNexus.Layers.classify(path)

  @doc "Does the project-root-relative `path` match any configured entry_points glob?"
  def entry_point?(%__MODULE__{entry_points: []}, _path), do: false

  def entry_point?(%__MODULE__{entry_points: globs}, path) when is_binary(path) do
    Enum.any?(globs, &glob_match?(&1, path))
  end

  def entry_point?(_, _), do: false

  @doc """
  Match a gitignore-style glob against a forward-slash path.
  `**` spans path segments, `*` matches within a segment, `?` one non-slash char.
  """
  def glob_match?(glob, path) when is_binary(glob) and is_binary(path) do
    Regex.match?(compile_glob(glob), path)
  end

  defp compile_glob(glob) do
    pattern =
      glob
      |> Regex.escape()
      # `**/` → optional run of leading directories
      |> String.replace("\\*\\*/", "§§DSTAR_SLASH§§")
      |> String.replace("\\*\\*", "§§DSTAR§§")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> String.replace("§§DSTAR_SLASH§§", "(?:.*/)?")
      |> String.replace("§§DSTAR§§", ".*")

    Regex.compile!("^" <> pattern <> "$")
  end
end
