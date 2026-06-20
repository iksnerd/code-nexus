defmodule ElixirNexus.Layers do
  @moduledoc """
  Derive a file's architectural layer from its path, by directory convention.

  This is the *derive-first* half of architecture awareness: with no configuration, Nexus
  infers the layer from well-known directory names anywhere in the path. A `.nexus.toml`
  `[layers]` section (handled in `ElixirNexus.ProjectConfig.layer_for/2`) overrides this for
  projects that don't follow the convention.

  Layers are checked most-specific first, so `core/ports/...` classifies as `ports`, not
  `domain`, even though `core` also appears. Returns `"other"` when nothing matches.
  """

  # {layer, dir-name aliases}. Order matters — earlier entries win.
  @conventions [
    {"ports", ~w(ports port contracts)},
    {"adapters", ~w(adapters adapter infrastructure infra)},
    {"domain", ~w(entities entity domain core models model)},
    {"application", ~w(services service usecases use-cases application app-services)},
    {"repositories", ~w(repositories repository repos repo)},
    {"api", ~w(api routes route controllers controller)},
    {"presentation", ~w(components component pages page views view ui hooks app)},
    {"lib", ~w(lib utils util helpers helper shared common)}
  ]

  @doc "Classify a path (relative or absolute) into a layer by directory convention."
  def classify(path) when is_binary(path) do
    segments = path |> Path.split() |> Enum.map(&String.downcase/1) |> MapSet.new()

    Enum.find_value(@conventions, "other", fn {layer, names} ->
      if Enum.any?(names, &MapSet.member?(segments, &1)), do: layer
    end)
  end

  def classify(_), do: "other"
end
