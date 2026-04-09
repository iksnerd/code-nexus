defmodule ElixirNexus.Parser do
  @moduledoc """
  Parses Elixir source files using Sourceror and extracts code entities.
  """
  require Logger

  def parse_file(file_path) do
    with {:ok, source_code} <- File.read(file_path) do
      parse_source(file_path, source_code)
    else
      {:error, reason} ->
        Logger.error("Failed to read file #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def parse_source(file_path, source_code) do
    case Sourceror.parse_string(source_code) do
      {:ok, ast} ->
        entities = extract_entities(file_path, ast, source_code)
        {:ok, entities}

      {:error, reason} ->
        Logger.error("Parse error in #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_entities(file_path, ast, source_code) do
    # Sourceror can return a single node or a list of nodes
    entities =
      case ast do
        list when is_list(list) ->
          list
          |> Enum.filter(&is_code_entity/1)

        single_node when is_tuple(single_node) ->
          if is_code_entity(single_node) do
            [single_node]
          else
            []
          end

        _other ->
          []
      end

    # Extract entities, and for modules, also extract functions within them
    entities
    |> Enum.flat_map(fn entity ->
      primary = ElixirNexus.CodeSchema.from_ast(file_path, entity, source_code)

      # If it's a module, also extract functions/macros inside it
      functions =
        case entity do
          {:defmodule, _, [_ | rest]} ->
            extract_module_functions(file_path, rest, source_code)

          _ ->
            []
        end

      [primary | functions]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp extract_module_functions(file_path, rest, source_code) do
    case rest do
      [body_list] when is_list(body_list) ->
        body_list
        |> Enum.flat_map(fn
          {{:__block__, _, [:do]}, body} ->
            # The body might be a __block__ containing multiple functions
            # or might be individual functions wrapped in {:__block__, [:do]} tuples
            case body do
              {:__block__, _, children} when is_list(children) ->
                # Multiple functions - extract functions from the children list
                children
                |> Enum.flat_map(fn
                  {{:__block__, _, [:do]}, func} -> extract_function(file_path, func, source_code)
                  func -> extract_function(file_path, func, source_code)
                end)

              other ->
                # Single function or something else
                extract_function(file_path, other, source_code)
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp extract_function(file_path, func_node, source_code) do
    case func_node do
      {:def, _, _} = def_node ->
        result = ElixirNexus.CodeSchema.from_ast(file_path, def_node, source_code)
        if result, do: [result], else: []

      {:defp, _, _} = defp_node ->
        result = ElixirNexus.CodeSchema.from_ast(file_path, defp_node, source_code)
        if result, do: [result], else: []

      {:defmacro, _, _} = defmacro_node ->
        result = ElixirNexus.CodeSchema.from_ast(file_path, defmacro_node, source_code)
        if result, do: [result], else: []

      _ ->
        []
    end
  end

  defp is_code_entity({:defmodule, _, _}), do: true
  defp is_code_entity({:def, _, _}), do: true
  defp is_code_entity({:defmacro, _, _}), do: true
  defp is_code_entity({:defp, _, _}), do: true
  defp is_code_entity({:defstruct, _, _}), do: true
  defp is_code_entity(_), do: false
end
