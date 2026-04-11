defmodule ElixirNexus.MCPServer.ResponseFormat do
  @moduledoc "Safe JSON encoding and compact result formatting for MCP tool responses."

  @doc "Encode data as JSON and wrap in MCP text content. Returns error text on serialisation failure."
  def json_reply(data, state) do
    case Jason.encode(data) do
      {:ok, json} ->
        {:ok, %{content: [%{type: "text", text: json}]}, state}

      {:error, reason} ->
        {:error, "Failed to serialize result: #{inspect(reason)}", state}
    end
  end

  @doc "Strip full source content from a list of search results to save tokens."
  def compact_results(results) when is_list(results) do
    Enum.map(results, &compact_result/1)
  end

  defp compact_result(%{entity: entity} = result) when is_map(entity) do
    result
    |> Map.put(:entity, compact_entity(entity))
    |> Map.drop([:vector_score, :keyword_score])
  end

  defp compact_result(%{name: _, resolved: false} = unresolved), do: unresolved

  defp compact_result(other), do: other

  defp compact_entity(entity) when is_map(entity) do
    calls = entity["calls"] || []

    %{
      "name" => entity["name"],
      "file_path" => entity["file_path"],
      "entity_type" => entity["entity_type"],
      "start_line" => entity["start_line"],
      "end_line" => entity["end_line"],
      "visibility" => entity["visibility"],
      "parameters" => entity["parameters"] || [],
      "calls" => Enum.take(calls, 10)
    }
  end

  @doc "Coerce MCP JSON string args to integer. MCP args arrive as strings even for numeric params."
  def to_int(val, _default) when is_integer(val), do: val

  def to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  def to_int(_, default), do: default
end
