defmodule ElixirNexus.Search do
  @moduledoc """
  Hybrid search combining dense vector similarity, sparse keyword matching via
  Qdrant's native RRF fusion, and graph re-ranking.
  """
  require Logger

  alias ElixirNexus.Search.Scoring
  alias ElixirNexus.Search.GraphBoost
  alias ElixirNexus.Search.Queries

  @ast_noise ~w(
    __block__ __aliases__ -> = :: << >> & |> fn {} %{} . @ \\\\ | <- <<>>
    == != || + - * / > < >= <= in not and or
    sigil_r sigil_H is_list length
    use require import alias moduledoc doc shortdoc
    defstruct defdelegate behaviour callback impl
  )
  @temp_prefixes ["/var/", "/tmp/", "/private/var/", "/private/tmp/"]

  @doc """
  Hybrid search: Qdrant-native RRF fusion of dense + sparse vectors,
  followed by graph-based re-ranking.
  """
  def search_code(query, limit \\ 10) do
    search_start = System.monotonic_time()
    Logger.info("Hybrid search for: #{query}")

    # Step 1: Get dense embedding from Bumblebee (falls back to TF-IDF)
    embedding = get_embedding(query)

    # Step 2: Get sparse keyword vector (boost query terms for name matching)
    boosted_query = String.duplicate("#{query} ", 3)
    sparse_vec = ElixirNexus.TFIDFEmbedder.sparse_vector(boosted_query)

    # Step 3: Qdrant-native hybrid search with RRF fusion
    results =
      case ElixirNexus.QdrantClient.hybrid_search(embedding, sparse_vec, limit * 3) do
        {:ok, %{"result" => %{"points" => points}}} when is_list(points) ->
          Logger.info("Hybrid search: got #{length(points)} results from Qdrant (points key)")

          points
          |> Enum.map(fn point ->
            %{
              id: point["id"],
              score: point["score"] || 0.0,
              entity: format_payload(point["payload"])
            }
          end)
          |> Enum.reject(&(&1.entity["name"] == "Unknown"))

        {:ok, %{"result" => points}} when is_list(points) ->
          Logger.info("Hybrid search: got #{length(points)} results from Qdrant (flat result)")

          points
          |> Enum.map(fn point ->
            %{
              id: point["id"],
              score: point["score"] || 0.0,
              entity: format_payload(point["payload"])
            }
          end)
          |> Enum.reject(&(&1.entity["name"] == "Unknown"))

        {:ok, other} ->
          Logger.warning("Hybrid search: unexpected result shape: #{inspect(Map.keys(other))}")
          fallback_dense_search(embedding, limit * 3)

        {:error, reason} ->
          Logger.warning("Hybrid search error: #{inspect(reason)}")
          fallback_dense_search(embedding, limit * 3)
      end

    # Step 4: Deduplicate by name+type
    deduped = Scoring.deduplicate(results)

    # Step 5: Graph re-ranking (prefer ETS cache, fallback to building from results)
    reranked =
      if length(deduped) > 0 do
        graph =
          case ElixirNexus.GraphCache.all_nodes() do
            nodes when map_size(nodes) > 0 -> nodes
            _ -> ElixirNexus.RelationshipGraph.build_graph(deduped)
          end

        GraphBoost.apply_graph_boost(deduped, graph)
      else
        deduped
      end

    # Step 6: Final sort, filter temp files, and limit
    final =
      reranked
      |> Enum.reject(fn r ->
        path = r.entity["file_path"] || ""
        Enum.any?(@temp_prefixes, &String.starts_with?(path, &1))
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    result =
      if final == [] do
        Logger.info("No hybrid results, falling back to indexer keyword search")
        keyword_search_fallback(query, limit)
      else
        {:ok, final}
      end

    duration_ms = System.convert_time_unit(System.monotonic_time() - search_start, :native, :millisecond)

    :telemetry.execute([:nexus, :search, :query], %{duration_ms: duration_ms, result_count: length(elem(result, 1))}, %{
      query: query
    })

    result
  end

  # Delegate query functions to Queries submodule
  defdelegate find_callees(entity_name, limit \\ 20), to: Queries
  defdelegate find_callers(entity_name, limit \\ 20), to: Queries
  defdelegate analyze_impact(entity_name, depth \\ 3), to: Queries
  defdelegate get_community_context(file_path, limit \\ 10), to: Queries
  defdelegate get_graph_stats(), to: Queries
  defdelegate find_module_hierarchy(entity_name), to: Queries
  defdelegate find_dead_code(opts \\ []), to: Queries

  defp get_embedding(query) do
    case ElixirNexus.EmbeddingModel.embed(query) do
      {:ok, embedding} ->
        embedding

      {:error, _} ->
        case ElixirNexus.TFIDFEmbedder.embed(query) do
          {:ok, embedding} -> embedding
          _ -> List.duplicate(0.0, 768)
        end
    end
  end

  defp fallback_dense_search(embedding, limit) do
    case ElixirNexus.QdrantClient.search(embedding, limit) do
      {:ok, %{"result" => points}} when is_list(points) ->
        points
        |> Enum.map(fn point ->
          %{
            id: point["id"],
            score: point["score"] || 0.0,
            entity: format_payload(point["payload"])
          }
        end)
        |> Enum.reject(&(&1.entity["name"] == "Unknown"))

      _ ->
        []
    end
  end

  defp keyword_search_fallback(query, limit) do
    try do
      case ElixirNexus.Indexer.search_chunks(query, limit) do
        {:ok, results} -> {:ok, results}
        {:error, _} -> {:ok, []}
      end
    rescue
      _ -> {:ok, []}
    end
  end

  @doc false
  def format_payload(payload) when is_map(payload) do
    %{
      "file_path" => payload["file_path"],
      "entity_type" => payload["entity_type"],
      "name" => payload["name"],
      "start_line" => payload["start_line"],
      "end_line" => payload["end_line"],
      "content" => payload["content"],
      "visibility" => payload["visibility"],
      "parameters" => payload["parameters"] || [],
      "calls" => filter_ast_noise(payload["calls"] || []),
      "is_a" => filter_ast_noise(payload["is_a"] || []),
      "contains" => filter_ast_noise(payload["contains"] || []),
      "language" => payload["language"]
    }
  end

  def format_payload(nil) do
    %{
      "file_path" => nil,
      "entity_type" => "unknown",
      "name" => "Unknown",
      "start_line" => 0,
      "end_line" => 0,
      "content" => "",
      "visibility" => nil,
      "parameters" => [],
      "calls" => [],
      "is_a" => [],
      "contains" => [],
      "language" => nil
    }
  end

  @doc false
  def filter_ast_noise(list) when is_list(list) do
    Enum.reject(list, &(&1 in @ast_noise))
  end
end
