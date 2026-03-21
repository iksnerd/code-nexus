defmodule ElixirNexus.CodeSchema do
  @moduledoc """
  Represents the structure of parsed code.
  """

  defstruct [
    :file_path,
    :entity_type,
    :name,
    :content,
    :start_line,
    :end_line,
    :docstring,
    :module_path,
    :parameters,
    :visibility,
    :calls,
    :is_a,
    :contains,
    :language
  ]

  @type t :: %__MODULE__{
          file_path: String.t(),
          entity_type: :function | :module | :struct | :macro | :test | :class | :method | :interface,
          name: String.t(),
          content: String.t(),
          start_line: non_neg_integer(),
          end_line: non_neg_integer(),
          docstring: String.t() | nil,
          module_path: String.t() | nil,
          parameters: list(String.t()),
          visibility: :public | :private | nil,
          calls: list(String.t()),
          is_a: list(String.t()),
          contains: list(String.t()),
          language: atom() | nil
        }

  @doc """
  Create a function/module entity from parsed AST node.
  """
  def from_ast(file_path, ast_node, source_code) do
    case ast_node do
      {:defmodule, meta, [module_name | rest]} ->
        {start_line, end_line} = extract_lines(meta)
        # Extract module name from {:__aliases__, ..., parts}
        module_str = 
          case module_name do
            {:__aliases__, _, parts} ->
              parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
            other ->
              inspect(other)
          end
        
        # Extract body from Sourceror's structure
        body = extract_module_body(rest)

        %__MODULE__{
          file_path: file_path,
          entity_type: :module,
          name: module_str,
          content: extract_content(source_code, start_line, end_line),
          start_line: start_line,
          end_line: end_line,
          module_path: module_str,
          parameters: [],
          visibility: :public,
          calls: ElixirNexus.RelationshipExtractor.extract_calls(body),
          is_a: ElixirNexus.RelationshipExtractor.extract_is_a(body),
          contains: ElixirNexus.RelationshipExtractor.extract_contains(ast_node)
        }

      # def with when guard (Sourceror wraps guards in :when node)
      {def_type, meta, [{:when, _, [{func_name, _, params}, _guard]} | body_rest]}
      when def_type in [:def, :defp] ->
        {start_line, end_line} = extract_lines(meta)
        body = extract_body_from_rest(body_rest)
        visibility = if def_type == :def, do: :public, else: :private

        %__MODULE__{
          file_path: file_path,
          entity_type: :function,
          name: to_string(func_name),
          content: extract_content(source_code, start_line, end_line),
          start_line: start_line,
          end_line: end_line,
          parameters: extract_param_names(params),
          visibility: visibility,
          calls: ElixirNexus.RelationshipExtractor.extract_calls(body),
          is_a: [],
          contains: []
        }

      # defmacro with when guard
      {:defmacro, meta, [{:when, _, [{macro_name, _, params}, _guard]} | body_rest]} ->
        {start_line, end_line} = extract_lines(meta)
        body = extract_body_from_rest(body_rest)

        %__MODULE__{
          file_path: file_path,
          entity_type: :macro,
          name: to_string(macro_name),
          content: extract_content(source_code, start_line, end_line),
          start_line: start_line,
          end_line: end_line,
          parameters: extract_param_names(params),
          visibility: :public,
          calls: ElixirNexus.RelationshipExtractor.extract_calls(body),
          is_a: [],
          contains: []
        }

      # def/defp without guard
      {def_type, meta, [{func_name, _, params} | body_rest]}
      when def_type in [:def, :defp] and is_atom(func_name) ->
        {start_line, end_line} = extract_lines(meta)
        body = extract_body_from_rest(body_rest)
        visibility = if def_type == :def, do: :public, else: :private

        %__MODULE__{
          file_path: file_path,
          entity_type: :function,
          name: to_string(func_name),
          content: extract_content(source_code, start_line, end_line),
          start_line: start_line,
          end_line: end_line,
          parameters: extract_param_names(params),
          visibility: visibility,
          calls: ElixirNexus.RelationshipExtractor.extract_calls(body),
          is_a: [],
          contains: []
        }

      # defmacro without guard
      {:defmacro, meta, [{macro_name, _, params} | body_rest]} when is_atom(macro_name) ->
        {start_line, end_line} = extract_lines(meta)
        body = extract_body_from_rest(body_rest)

        %__MODULE__{
          file_path: file_path,
          entity_type: :macro,
          name: to_string(macro_name),
          content: extract_content(source_code, start_line, end_line),
          start_line: start_line,
          end_line: end_line,
          parameters: extract_param_names(params),
          visibility: :public,
          calls: ElixirNexus.RelationshipExtractor.extract_calls(body),
          is_a: [],
          contains: []
        }

      {:defstruct, meta, fields} ->
        {start_line, end_line} = extract_lines(meta)

        %__MODULE__{
          file_path: file_path,
          entity_type: :struct,
          name: "defstruct",
          content: extract_content(source_code, start_line, end_line),
          start_line: start_line,
          end_line: end_line,
          parameters: extract_struct_fields(fields),
          visibility: :public,
          calls: [],
          is_a: [],
          contains: []
        }

      _ ->
        nil
    end
  end

  defp extract_lines(meta) do
    line = Keyword.get(meta, :line, 0)
    # Sourceror provides :end_of_expression or :closing metadata for accurate end lines
    end_line =
      case Keyword.get(meta, :end_of_expression) do
        nil ->
          case Keyword.get(meta, :closing) do
            nil -> Keyword.get(meta, :end_line, line)
            closing -> Keyword.get(closing, :line, Keyword.get(meta, :end_line, line))
          end
        end_expr ->
          Keyword.get(end_expr, :line, Keyword.get(meta, :end_line, line))
      end
    {line, end_line}
  end

  defp extract_body_from_rest(body_rest) do
    case body_rest do
      [[do: body]] -> body
      [[{{:__block__, _, [:do]}, body}]] -> body
      _ -> nil
    end
  end

  defp extract_content(source_code, start_line, end_line) when start_line > 0 and end_line > 0 do
    source_code
    |> String.split("\n")
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp extract_content(_source_code, _start_line, _end_line), do: ""

  defp extract_param_names(params) when is_list(params) do
    params
    |> Enum.map(fn
      {name, _, _} -> to_string(name)
      name when is_atom(name) -> to_string(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_param_names(_), do: []

  defp extract_struct_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      {key, _value} -> to_string(key)
      key when is_atom(key) -> to_string(key)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_struct_fields(_), do: []

  defp extract_module_body([body_list]) when is_list(body_list) do
    # Sourceror structure: [{{:__block__, [:do]}, actual_body}, ...]
    # Extract the second element of each tuple (the actual body)
    body_list
    |> Enum.map(fn
      {{:__block__, _, [:do]}, body} -> body
      other -> other
    end)
  end
  
  defp extract_module_body(other) do
    other
  end

end
