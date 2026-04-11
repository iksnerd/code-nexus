defmodule ElixirNexus.Search.CommunityContext do
  @moduledoc "Find files structurally coupled to a given file via shared call and import edges."

  require Logger

  alias ElixirNexus.Search.{DataFetching, EntityResolution}

  @doc """
  Find files structurally coupled to the given file via shared call edges.
  Returns top `limit` files ranked by coupling strength.
  """
  def get_community_context(file_path, limit \\ 10) do
    Logger.info("Getting community context for: #{file_path}")

    case DataFetching.get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        target_entities = Enum.filter(all_entities, &(&1.entity["file_path"] == file_path))
        target_names = MapSet.new(target_entities, & &1.entity["name"])
        # Build lowercase index for O(1) name matching
        target_names_lower = MapSet.new(target_names, &String.downcase/1)
        # Exclude internal calls (calls that resolve to same-file entities)
        target_calls =
          target_entities
          |> Enum.flat_map(&(&1.entity["calls"] || []))
          |> Enum.reject(fn call ->
            call_lower = String.downcase(call)

            MapSet.member?(target_names_lower, call_lower) or
              Enum.any?(target_names, &EntityResolution.matches_entity_name?(call, &1))
          end)

        target_calls_lower = MapSet.new(target_calls, &String.downcase/1)

        coupled =
          all_entities
          |> Enum.reject(&(&1.entity["file_path"] == file_path))
          |> Enum.flat_map(fn entity ->
            name = entity.entity["name"] || ""
            name_lower = String.downcase(name)
            calls = entity.entity["calls"] || []
            other_path = entity.entity["file_path"]

            # They call us (outgoing_hits) — check calls against target names
            outgoing =
              calls
              |> Enum.filter(fn c ->
                c_lower = String.downcase(c)

                MapSet.member?(target_names_lower, c_lower) or
                  Enum.any?(target_names, &EntityResolution.matches_entity_name?(c, &1))
              end)
              |> Enum.map(fn c ->
                target = Enum.find(target_names, &EntityResolution.matches_entity_name?(c, &1))
                %{from: name, to: target, direction: :incoming}
              end)

            # We call them (incoming_hits) — check if target calls this entity
            incoming =
              if MapSet.member?(target_calls_lower, name_lower) or
                   Enum.any?(target_calls, &EntityResolution.matches_entity_name?(&1, name)) do
                caller =
                  Enum.find(target_entities, fn te ->
                    Enum.any?(te.entity["calls"] || [], &EntityResolution.matches_entity_name?(&1, name))
                  end)

                [%{from: (caller && caller.entity["name"]) || "unknown", to: name, direction: :outgoing}]
              else
                []
              end

            # Import-path coupling: check all entities' is_a (import sources)
            import_connections =
              (entity.entity["is_a"] || [])
              |> Enum.filter(&EntityResolution.import_matches_file?(&1, file_path))
              |> Enum.map(fn _imp ->
                %{from: name, to: Path.basename(file_path), direction: :imports}
              end)

            # Reverse import coupling: check if target file's entities import from this entity's file
            reverse_import_connections =
              target_entities
              |> Enum.flat_map(fn te ->
                (te.entity["is_a"] || [])
                |> Enum.filter(&EntityResolution.import_matches_file?(&1, other_path))
                |> Enum.map(fn _imp ->
                  %{from: Path.basename(file_path), to: name, direction: :imported_by}
                end)
              end)

            connections = outgoing ++ incoming ++ import_connections ++ reverse_import_connections

            if connections != [] do
              [{other_path, length(connections), connections}]
            else
              []
            end
          end)
          |> Enum.group_by(&elem(&1, 0))
          |> Enum.map(fn {path, entries} ->
            score = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()
            connections = entries |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()
            %{file_path: path, coupling_score: score, connections: connections}
          end)
          |> Enum.sort_by(& &1.coupling_score, :desc)
          |> Enum.take(limit)

        {:ok,
         %{
           file: file_path,
           entities_in_file: length(target_entities),
           coupled_files: coupled
         }}

      error ->
        error
    end
  end
end
