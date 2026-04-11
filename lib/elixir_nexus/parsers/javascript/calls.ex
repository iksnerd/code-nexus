defmodule ElixirNexus.Parsers.JavaScript.Calls do
  @moduledoc "Call-edge extraction from JavaScript/TypeScript tree-sitter AST nodes."

  @doc "Extract all function/method call names from an AST node's children."
  def extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def extract_calls(_), do: []

  # call_expression with a name field (e.g. tree-sitter provides it directly)
  defp find_calls(%{"kind" => "call_expression", "name" => name}) when is_binary(name) and name != "" do
    [name]
  end

  # call_expression — extract the callee name, recurse into arguments (not callee) to avoid duplicates
  defp find_calls(%{"kind" => "call_expression", "children" => children}) do
    callee_node =
      Enum.find(children, fn child ->
        child["kind"] in ["identifier", "member_expression", "call_expression"]
      end)

    callee_name = extract_callee_name(callee_node)

    # Only recurse into non-callee children (arguments, etc.) to avoid duplicate extraction
    non_callee = if callee_node, do: children -- [callee_node], else: children
    argument_calls = Enum.flat_map(non_callee, &find_calls/1)

    # Recurse into the callee chain for nested calls (e.g., db.collection().doc().set())
    callee_chain_calls = find_calls_in_callee(callee_node)

    all_calls = argument_calls ++ callee_chain_calls

    case callee_name do
      nil -> all_calls
      name -> [name | all_calls]
    end
  end

  defp find_calls(%{"kind" => "call_expression"}), do: []

  # new Foo() expressions
  defp find_calls(%{"kind" => "new_expression", "children" => children}) do
    callee =
      children
      |> Enum.find(&(&1["kind"] == "identifier"))
      |> then(fn
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end)

    rest = Enum.flat_map(children, &find_calls/1)
    if callee, do: [callee | rest], else: rest
  end

  # member_expression — recurse to find chained calls (e.g., db.collection().doc().set())
  defp find_calls(%{"kind" => "member_expression", "children" => children}) do
    Enum.flat_map(children, &find_calls/1)
  end

  # JSX self-closing elements: <Button />, <Card /> → treat as calls to the component
  defp find_calls(%{"kind" => kind, "children" => children})
       when kind in ["jsx_self_closing_element", "jsx_opening_element"] do
    tag_name =
      children
      |> Enum.find(&(&1["kind"] == "identifier"))
      |> then(fn
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end)

    # Only track PascalCase components — skip intrinsic HTML elements (div, span, etc.)
    rest = Enum.flat_map(children, &find_calls/1)

    if tag_name && Regex.match?(~r/^[A-Z]/, tag_name) do
      [tag_name | rest]
    else
      rest
    end
  end

  # Recurse into other nodes with children
  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  # Recurse into callee chain to find nested call_expressions without double-counting
  defp find_calls_in_callee(%{"kind" => "member_expression", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "call_expression"))
    |> Enum.flat_map(&find_calls/1)
  end

  defp find_calls_in_callee(%{"kind" => "call_expression"} = node), do: find_calls(node)
  defp find_calls_in_callee(_), do: []

  # Extract a readable name from a callee node
  defp extract_callee_name(%{"kind" => "identifier", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(%{"kind" => "identifier", "name" => name}) when is_binary(name), do: name

  defp extract_callee_name(%{"kind" => "member_expression", "children" => children}) do
    # For simple member expressions like "db.collection", join identifiers
    # For chained calls like "db.collection('x').doc", extract just the property (last identifier)
    has_call_child = Enum.any?(children, &(&1["kind"] == "call_expression"))

    if has_call_child do
      # Chained: foo().bar — extract just "bar" (the property being accessed)
      children
      |> Enum.find(&(&1["kind"] == "property_identifier"))
      |> then(fn
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end)
    else
      # Simple: db.collection — join all identifiers
      parts =
        children
        |> Enum.filter(&(&1["kind"] in ["identifier", "property_identifier"]))
        |> Enum.map(&(&1["text"] || &1["name"] || ""))
        |> Enum.reject(&(&1 == ""))

      case parts do
        [] -> nil
        _ -> Enum.join(parts, ".")
      end
    end
  end

  defp extract_callee_name(%{"kind" => "member_expression", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(_), do: nil
end
