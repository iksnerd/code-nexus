defmodule ElixirNexus.RelationshipExtractor do
  @moduledoc """
  Extracts relationships from Elixir code AST:
  - CALLS: Function calls (downstream)
  - IS_A: use/import statements (inheritance/mixins)
  - CONTAINS: Module contains functions (hierarchy)
  """

  require Logger

  defstruct [
    :calls,
    :is_a,
    :contains
  ]

  @type t :: %__MODULE__{
          calls: list(String.t()),
          is_a: list(String.t()),
          contains: list(String.t())
        }

  @doc """
  Extract all relationships from an AST node.
  """
  def extract(ast_node) do
    %__MODULE__{
      calls: extract_calls(ast_node),
      is_a: extract_is_a(ast_node),
      contains: extract_contains(ast_node)
    }
  end

  @doc """
  Extract "Calls" relationships (functions called by this function).
  Handles both qualified (Module.func) and unqualified (func) calls.
  """
  def extract_calls(ast_node) do
    ast_node
    |> walk_calls([])
    |> Enum.uniq()
  end

  @doc """
  Extract "Is-A" relationships (use/import statements).
  Detects module capabilities and mixins.
  """
  def extract_is_a(ast_node) do
    ast_node
    |> walk_is_a([])
    |> Enum.uniq()
  end

  @doc """
  Extract "Contains" relationships (what this module contains).
  For a module, lists all functions/macros/structs inside it.
  """
  def extract_contains({:defmodule, _meta, [_name, [do: body]]}) do
    body
    |> walk_contains([])
    |> Enum.uniq()
  end

  def extract_contains({:defmodule, _meta, [_name, body_list]}) when is_list(body_list) do
    body_list
    |> Enum.flat_map(fn
      {{:__block__, _, [:do]}, body} -> walk_contains(body, [])
      other -> walk_contains(other, [])
    end)
    |> Enum.uniq()
  end

  def extract_contains(_other), do: []

  # === CALLS extraction ===
  defp walk_calls({func, _meta, args}, acc) when is_atom(func) and is_list(args) do
    # Skip definition forms and control flow
    if func in [:defmodule, :def, :defp, :defmacro, :if, :case, :cond, :try, :when] do
      args_calls = Enum.flat_map(args, &walk_calls(&1, []))
      args_calls ++ acc
    else
      # Unqualified call: function(args)
      new_call = to_string(func)
      args_calls = Enum.flat_map(args, &walk_calls(&1, []))
      [new_call | args_calls] ++ acc
    end
  end

  # Qualified call: Module.function(args)
  defp walk_calls({{:., _, [{:__aliases__, _, parts}, func_name]}, _meta, args}, acc) do
    qualified_name =
      parts
      |> Enum.map(&to_string/1)
      |> Enum.join(".")
      |> then(&"#{&1}.#{func_name}")

    args_calls = Enum.flat_map(args, &walk_calls(&1, []))
    [qualified_name | args_calls] ++ acc
  end

  defp walk_calls({left, right}, acc) do
    left_calls = walk_calls(left, [])
    right_calls = walk_calls(right, [])
    left_calls ++ right_calls ++ acc
  end

  defp walk_calls([head | tail], acc) do
    head_calls = walk_calls(head, [])
    tail_calls = walk_calls(tail, [])
    head_calls ++ tail_calls ++ acc
  end

  defp walk_calls(_other, acc), do: acc

  # === IS_A extraction ===
  defp walk_is_a({:use, _meta, [module_ast | _rest]}, acc) do
    case module_ast do
      {:__aliases__, _, parts} ->
        module_name =
          parts
          |> Enum.map(&to_string/1)
          |> Enum.join(".")

        [module_name | acc]

      module_atom when is_atom(module_atom) ->
        [to_string(module_atom) | acc]

      _ ->
        acc
    end
  end

  defp walk_is_a({:import, _meta, [module_ast | _rest]}, acc) do
    case module_ast do
      {:__aliases__, _, parts} ->
        module_name =
          parts
          |> Enum.map(&to_string/1)
          |> Enum.join(".")

        [module_name | acc]

      module_atom when is_atom(module_atom) ->
        [to_string(module_atom) | acc]

      _ ->
        acc
    end
  end

  defp walk_is_a({:require, _meta, [module_ast | _rest]}, acc) do
    case module_ast do
      {:__aliases__, _, parts} ->
        module_name =
          parts
          |> Enum.map(&to_string/1)
          |> Enum.join(".")

        [module_name | acc]

      module_atom when is_atom(module_atom) ->
        [to_string(module_atom) | acc]

      _ ->
        acc
    end
  end

  defp walk_is_a({_type, _meta, args}, acc) when is_list(args) do
    Enum.flat_map(args, &walk_is_a(&1, []))
    |> Enum.concat(acc)
  end

  defp walk_is_a({left, right}, acc) do
    left_rels = walk_is_a(left, [])
    right_rels = walk_is_a(right, [])
    left_rels ++ right_rels ++ acc
  end

  defp walk_is_a([head | tail], acc) do
    head_rels = walk_is_a(head, [])
    tail_rels = walk_is_a(tail, [])
    head_rels ++ tail_rels ++ acc
  end

  defp walk_is_a(_other, acc), do: acc

  # === CONTAINS extraction ===
  # Guarded functions: def func(...) when guard do
  defp walk_contains({def_type, _meta, [{:when, _, [{func_name, _, _params}, _guard]} | _rest]}, acc)
       when def_type in [:def, :defp, :defmacro] do
    [to_string(func_name) | acc]
  end

  defp walk_contains({:def, _meta, [{func_name, _, _params} | _rest]}, acc) do
    [to_string(func_name) | acc]
  end

  defp walk_contains({:defp, _meta, [{func_name, _, _params} | _rest]}, acc) do
    [to_string(func_name) | acc]
  end

  defp walk_contains({:defmacro, _meta, [{macro_name, _, _params} | _rest]}, acc) do
    [to_string(macro_name) | acc]
  end

  defp walk_contains({:defstruct, _meta, _fields}, acc) do
    ["defstruct" | acc]
  end

  defp walk_contains({_type, _meta, args}, acc) when is_list(args) do
    Enum.flat_map(args, &walk_contains(&1, []))
    |> Enum.concat(acc)
  end

  defp walk_contains({left, right}, acc) do
    left_ents = walk_contains(left, [])
    right_ents = walk_contains(right, [])
    left_ents ++ right_ents ++ acc
  end

  defp walk_contains([head | tail], acc) do
    head_ents = walk_contains(head, [])
    tail_ents = walk_contains(tail, [])
    head_ents ++ tail_ents ++ acc
  end

  defp walk_contains(_other, acc), do: acc
end
