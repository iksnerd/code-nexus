defmodule ElixirNexus.Parsers.Go.Calls do
  @moduledoc "Call-edge extraction from Go tree-sitter AST nodes."

  @doc "Extract all function/method call names from an AST node's children."
  def extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def extract_calls(_), do: []

  # call_expression with a top-level name (unlikely in Go tree-sitter, but handle it)
  defp find_calls(%{"kind" => "call_expression", "name" => name}) when is_binary(name) and name != "" do
    [name]
  end

  # call_expression — extract callee from children
  defp find_calls(%{"kind" => "call_expression", "children" => children}) do
    callee_node =
      Enum.find(children, fn child ->
        child["kind"] in ["identifier", "selector_expression", "call_expression"]
      end)

    callee_name = extract_callee_name(callee_node)

    # Recurse into argument_list for nested calls
    arg_calls =
      children
      |> Enum.filter(&(&1["kind"] == "argument_list"))
      |> Enum.flat_map(&find_calls/1)

    # Recurse into callee for chained calls
    callee_chain_calls = find_calls_in_callee(callee_node)

    all_calls = arg_calls ++ callee_chain_calls

    case callee_name do
      nil -> all_calls
      name -> [name | all_calls]
    end
  end

  defp find_calls(%{"kind" => "call_expression"}), do: []

  # Recurse into other nodes
  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  # Extract callee name from the function child of a call_expression
  defp extract_callee_name(%{"kind" => "identifier", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(%{"kind" => "identifier", "name" => name}) when is_binary(name), do: name

  defp extract_callee_name(%{"kind" => "selector_expression", "children" => children}) do
    # selector_expression: operand (identifier) + field_identifier
    # e.g., fmt.Println -> ["fmt", "Println"] -> "fmt.Println"
    has_call_child = Enum.any?(children, &(&1["kind"] == "call_expression"))

    if has_call_child do
      # Chained: foo().Bar — extract just the field
      children
      |> Enum.find(&(&1["kind"] == "field_identifier"))
      |> case do
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end
    else
      # Simple: pkg.Function — join operand + field
      parts =
        children
        |> Enum.filter(&(&1["kind"] in ["identifier", "field_identifier"]))
        |> Enum.map(&(&1["text"] || &1["name"] || ""))
        |> Enum.reject(&(&1 == ""))

      case parts do
        [] -> nil
        _ -> Enum.join(parts, ".")
      end
    end
  end

  defp extract_callee_name(%{"kind" => "selector_expression", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(_), do: nil

  # Recurse into callee chain for chained calls
  defp find_calls_in_callee(%{"kind" => "selector_expression", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "call_expression"))
    |> Enum.flat_map(&find_calls/1)
  end

  defp find_calls_in_callee(%{"kind" => "call_expression"} = node), do: find_calls(node)
  defp find_calls_in_callee(_), do: []
end
