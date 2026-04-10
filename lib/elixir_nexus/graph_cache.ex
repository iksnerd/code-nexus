defmodule ElixirNexus.GraphCache do
  @moduledoc "ETS-backed relationship graph cache for O(1) lookups."

  @table :nexus_graph_cache

  def table_name, do: @table

  @doc false
  def ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

  def put_node(entity_id, node) do
    ensure_table()
    :ets.insert(@table, {entity_id, node})
    :ok
  end

  def get_node(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, node}] -> node
      [] -> nil
    end
  end

  def all_nodes do
    :ets.foldl(fn {id, node}, acc -> Map.put(acc, id, node) end, %{}, @table)
  end

  def find_callers(entity_name) do
    name_lower = String.downcase(entity_name)

    :ets.foldl(
      fn {_id, node} = entry, acc ->
        if Enum.any?(node["calls"] || [], fn call ->
             String.contains?(String.downcase(call), name_lower)
           end) do
          [entry | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
  end

  @doc "Find entities that import/reference the given name via is_a edges."
  def find_importers(entity_name) do
    name_lower = String.downcase(entity_name)

    :ets.foldl(
      fn {_id, node} = entry, acc ->
        if Enum.any?(node["is_a"] || [], fn imp ->
             imp_lower = String.downcase(imp)
             String.contains?(imp_lower, name_lower)
           end) do
          [entry | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
  end

  @doc "Remove all graph nodes for a given file path."
  def delete_by_file(file_path) do
    ids_to_delete =
      :ets.foldl(
        fn {id, node}, acc ->
          if node["file_path"] == file_path, do: [id | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(ids_to_delete, &:ets.delete(@table, &1))
    :ok
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Full rebuild of graph cache from a list of chunks (maps with entity data)."
  def rebuild_from_chunks(chunks) when is_list(chunks) do
    clear()

    graph =
      ElixirNexus.RelationshipGraph.build_graph(
        Enum.map(chunks, fn chunk ->
          %{
            id: chunk.id,
            score: 0.0,
            entity: %{
              "name" => chunk.name,
              "entity_type" => Atom.to_string(chunk.entity_type),
              "file_path" => chunk.file_path,
              "calls" => ElixirNexus.Search.filter_ast_noise(chunk.calls || []),
              "is_a" => ElixirNexus.Search.filter_ast_noise(chunk.is_a || []),
              "contains" => ElixirNexus.Search.filter_ast_noise(chunk.contains || []),
              "start_line" => chunk.start_line,
              "end_line" => chunk.end_line,
              "content" => chunk.content
            }
          }
        end)
      )

    Enum.each(graph, fn {id, node} -> put_node(id, node) end)
    :ok
  end

  @doc "Incremental update: remove old entries for a file and insert new ones."
  def update_file(file_path, chunks) do
    # Collect IDs first, then delete — modifying ETS during foldl is unsafe
    ids_to_delete =
      :ets.foldl(
        fn {id, node}, acc ->
          if node["file_path"] == file_path, do: [id | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(ids_to_delete, &:ets.delete(@table, &1))

    # Insert new entries
    Enum.each(chunks, fn chunk ->
      entity_id = chunk.id || chunk.name

      node = %{
        "id" => entity_id,
        "name" => chunk.name,
        "type" => Atom.to_string(chunk.entity_type),
        "file_path" => chunk.file_path,
        "start_line" => chunk.start_line,
        "end_line" => chunk.end_line,
        "calls" => ElixirNexus.Search.filter_ast_noise(chunk.calls || []),
        "is_a" => ElixirNexus.Search.filter_ast_noise(chunk.is_a || []),
        "contains" => ElixirNexus.Search.filter_ast_noise(chunk.contains || []),
        "outgoing_degree" => length(chunk.calls || []) + length(chunk.is_a || []) + length(chunk.contains || []),
        "incoming_count" => 0
      }

      put_node(entity_id, node)
    end)

    :ok
  end
end
