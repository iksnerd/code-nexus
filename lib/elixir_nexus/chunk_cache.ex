defmodule ElixirNexus.ChunkCache do
  @moduledoc "ETS-backed chunk storage for concurrent reads and fast keyword search."

  @table :nexus_chunk_cache

  def table_name, do: @table

  @doc false
  def ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

  def insert_many(chunks) when is_list(chunks) do
    ensure_table()

    entries =
      Enum.map(chunks, fn chunk ->
        {chunk.file_path, chunk}
      end)

    :ets.insert(@table, entries)
    :ok
  end

  def search(query, limit \\ 10) do
    query_lower = String.downcase(query)

    # Use :ets.foldl to avoid copying the entire table into the process heap.
    # Collect up to `limit` matching chunks in a single traversal.
    # Use {count, results} accumulator for O(1) limit check per row.
    {_count, matches} =
      :ets.foldl(
        fn {_key, chunk}, {count, acc} ->
          if count >= limit do
            {count, acc}
          else
            if String.contains?(String.downcase(chunk.name), query_lower) ||
                 String.contains?(String.downcase(chunk.content), query_lower) do
              {count + 1, [chunk | acc]}
            else
              {count, acc}
            end
          end
        end,
        {0, []},
        @table
      )

    Enum.map(matches, fn chunk ->
      %{
        id: chunk.id,
        score: 1.0,
        entity: %{
          "file_path" => chunk.file_path,
          "entity_type" => Atom.to_string(chunk.entity_type),
          "name" => chunk.name,
          "start_line" => chunk.start_line,
          "end_line" => chunk.end_line,
          "module_path" => chunk.module_path,
          "visibility" => chunk.visibility && Atom.to_string(chunk.visibility),
          "parameters" => chunk.parameters,
          "calls" => chunk.calls,
          "is_a" => chunk.is_a,
          "contains" => chunk.contains,
          "content" => chunk.content,
          "language" => chunk[:language] && Atom.to_string(chunk[:language])
        }
      }
    end)
  end

  def count do
    case :ets.info(@table, :size) do
      :undefined -> 0
      n -> n
    end
  rescue
    _ -> 0
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  def delete_by_file(file_path) do
    :ets.delete(@table, file_path)
    :ok
  end

  def all do
    if :ets.info(@table) != :undefined do
      :ets.foldl(fn {_key, chunk}, acc -> [chunk | acc] end, [], @table)
    else
      []
    end
  end
end
