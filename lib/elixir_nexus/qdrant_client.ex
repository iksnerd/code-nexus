defmodule ElixirNexus.QdrantClient do
  @moduledoc "GenServer client for communicating with the Qdrant vector database."
  use GenServer
  require Logger

  @vector_size 384
  @distance "Cosine"
  @http_timeout 30_000

  defp qdrant_url do
    Application.get_env(:elixir_nexus, :qdrant_url) ||
      System.get_env("QDRANT_URL") ||
      "http://localhost:6333"
  end

  @doc "Returns the collection name derived from the project directory and Mix env."
  def collection_name do
    base =
      (System.get_env("NEXUS_COLLECTION") || project_collection_name())
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim_leading("_")
      |> String.slice(0..59)

    if Mix.env() == :test, do: base <> "_test", else: base
  end

  defp project_collection_name do
    File.cwd!()
    |> Path.basename()
    |> then(&"nexus_#{&1}")
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health_check do
    GenServer.call(__MODULE__, :health_check, @http_timeout)
  end

  def create_collection(vector_size) do
    GenServer.call(__MODULE__, {:create_collection, vector_size}, @http_timeout)
  end

  def upsert_point(id, vector, payload) do
    GenServer.call(__MODULE__, {:upsert_point, id, vector, payload}, @http_timeout)
  end

  @doc "Batch upsert multiple points in a single HTTP call."
  def upsert_points(points) when is_list(points) do
    GenServer.call(__MODULE__, {:upsert_points, points}, 120_000)
  end

  def search(vector, limit \\ 10) do
    GenServer.call(__MODULE__, {:search, vector, limit}, @http_timeout)
  end

  def search_with_filter(vector, filter, limit \\ 10) do
    GenServer.call(__MODULE__, {:search_with_filter, vector, filter, limit}, @http_timeout)
  end

  @doc """
  Hybrid search using Qdrant's query API with prefetch + RRF fusion.
  Combines dense semantic vector search with sparse keyword vector search.
  """
  def hybrid_search(embedding, sparse_vector, limit \\ 10) do
    GenServer.call(__MODULE__, {:hybrid_search, embedding, sparse_vector, limit}, @http_timeout)
  end

  def collection_info do
    GenServer.call(__MODULE__, :collection_info, @http_timeout)
  end

  def scroll_points(limit \\ 20, offset \\ nil, filter \\ nil) do
    GenServer.call(__MODULE__, {:scroll, limit, offset, filter}, @http_timeout)
  end

  def get_point(id) do
    GenServer.call(__MODULE__, {:get_point, id}, @http_timeout)
  end

  def delete_points(ids) when is_list(ids) do
    GenServer.call(__MODULE__, {:delete_points, ids}, @http_timeout)
  end

  def list_collections do
    GenServer.call(__MODULE__, :list_collections, @http_timeout)
  end

  def switch_collection(name) do
    GenServer.call(__MODULE__, {:switch_collection, name}, @http_timeout)
  end

  def active_collection do
    GenServer.call(__MODULE__, :active_collection)
  end

  def delete_collection do
    GenServer.call(__MODULE__, :delete_collection, @http_timeout)
  end

  def reset_collection do
    GenServer.call(__MODULE__, :reset_collection, @http_timeout)
  end

  def count_points(filter \\ nil) do
    GenServer.call(__MODULE__, {:count_points, filter}, @http_timeout)
  end

  @impl true
  def init(_opts) do
    url = qdrant_url()
    Logger.info("Initializing Qdrant client pointing to #{url}")

    case http_get("#{url}/") do
      {:ok, _} ->
        Logger.info("Qdrant is healthy")
        Process.send_after(self(), :ensure_collection, 1000)
        {:ok, %{url: url, collection: collection_name()}}

      {:error, reason} ->
        Logger.warning(
          "Qdrant health check failed: #{inspect(reason)}. Make sure Qdrant is running at #{url}"
        )
        {:ok, %{url: url, collection: collection_name()}}
    end
  end

  @impl true
  def handle_info(:ensure_collection, state) do
    case http_put("#{state.url}/collections/#{state.collection}", collection_schema()) do
      {:ok, _} ->
        Logger.info("Collection '#{state.collection}' ready (named vectors + sparse vectors)")

      {:error, reason} ->
        Logger.warning("Could not create collection: #{inspect(reason)}")
    end
    {:noreply, state}
  end

  defp collection_schema do
    %{
      "vectors" => %{
        "semantic" => %{
          "size" => @vector_size,
          "distance" => @distance
        }
      },
      "sparse_vectors" => %{
        "keywords" => %{
          "index" => %{"on_disk" => true}
        }
      }
    }
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    result = http_get_raw("#{state.url}/healthz")
    {:reply, result, state}
  end

  def handle_call({:create_collection, vector_size}, _from, state) do
    payload = %{
      "vectors" => %{
        "semantic" => %{
          "size" => vector_size,
          "distance" => @distance
        }
      },
      "sparse_vectors" => %{
        "keywords" => %{
          "index" => %{"on_disk" => true}
        }
      }
    }

    result = http_put("#{state.url}/collections/#{state.collection}", payload)
    {:reply, result, state}
  end

  def handle_call({:upsert_point, id, vector, payload}, _from, state) do
    body = %{
      "points" => [
        %{
          "id" => id,
          "vector" => %{"semantic" => vector},
          "payload" => payload
        }
      ]
    }

    result = http_put("#{state.url}/collections/#{state.collection}/points", body)
    {:reply, result, state}
  end

  def handle_call({:upsert_point, id, vector, sparse_vec, payload}, _from, state) do
    body = %{
      "points" => [
        %{
          "id" => id,
          "vector" => %{
            "semantic" => vector,
            "keywords" => sparse_vec
          },
          "payload" => payload
        }
      ]
    }

    result = http_put("#{state.url}/collections/#{state.collection}/points", body)
    {:reply, result, state}
  end

  def handle_call({:upsert_points, points}, _from, state) do
    start_time = System.monotonic_time()
    body = %{"points" => points}
    result = http_put("#{state.url}/collections/#{state.collection}/points", body)
    duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
    :telemetry.execute([:nexus, :qdrant, :upsert], %{duration_ms: duration_ms, point_count: length(points)}, %{})
    {:reply, result, state}
  end

  def handle_call({:search, vector, limit}, _from, state) do
    body = %{
      "vector" => %{"name" => "semantic", "vector" => vector},
      "limit" => limit,
      "with_payload" => true
    }

    result =
      http_post("#{state.url}/collections/#{state.collection}/points/search", body)

    {:reply, result, state}
  end

  def handle_call({:search_with_filter, vector, filter, limit}, _from, state) do
    body = %{
      "vector" => %{"name" => "semantic", "vector" => vector},
      "filter" => filter,
      "limit" => limit,
      "with_payload" => true
    }

    result =
      http_post("#{state.url}/collections/#{state.collection}/points/search", body)

    {:reply, result, state}
  end

  def handle_call({:hybrid_search, embedding, sparse_vector, limit}, _from, state) do
    start_time = System.monotonic_time()

    body = %{
      "prefetch" => [
        %{
          "query" => embedding,
          "using" => "semantic",
          "limit" => limit * 3
        },
        %{
          "query" => sparse_vector,
          "using" => "keywords",
          "limit" => limit * 3
        }
      ],
      "query" => %{"fusion" => "rrf"},
      "limit" => limit,
      "with_payload" => true
    }

    result =
      http_post("#{state.url}/collections/#{state.collection}/points/query", body)

    duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
    :telemetry.execute([:nexus, :qdrant, :hybrid_search], %{duration_ms: duration_ms, limit: limit}, %{})

    {:reply, result, state}
  end

  def handle_call(:list_collections, _from, state) do
    case http_get("#{state.url}/collections") do
      {:ok, data} ->
        names = Enum.map(data["result"]["collections"] || [], & &1["name"])
        {:reply, {:ok, names}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:switch_collection, name}, _from, state) do
    case http_get("#{state.url}/collections/#{name}") do
      {:ok, _} ->
        {:reply, :ok, %{state | collection: name}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:active_collection, _from, state) do
    {:reply, state.collection, state}
  end

  def handle_call({:switch_collection_force, name}, _from, state) do
    {:reply, :ok, %{state | collection: name}}
  end

  def handle_call(:collection_info, _from, state) do
    result = http_get("#{state.url}/collections/#{state.collection}")
    {:reply, result, state}
  end

  def handle_call({:scroll, limit, offset, filter}, _from, state) do
    body =
      %{"limit" => limit, "with_payload" => true}
      |> then(fn b -> if offset, do: Map.put(b, "offset", offset), else: b end)
      |> then(fn b -> if filter, do: Map.put(b, "filter", filter), else: b end)

    result = http_post("#{state.url}/collections/#{state.collection}/points/scroll", body)
    {:reply, result, state}
  end

  def handle_call({:get_point, id}, _from, state) do
    result = http_get("#{state.url}/collections/#{state.collection}/points/#{id}")
    {:reply, result, state}
  end

  def handle_call({:delete_points, ids}, _from, state) do
    body = %{"points" => ids}
    result = http_post("#{state.url}/collections/#{state.collection}/points/delete", body)
    {:reply, result, state}
  end

  def handle_call(:delete_collection, _from, state) do
    result = http_delete("#{state.url}/collections/#{state.collection}")
    {:reply, result, state}
  end

  def handle_call(:reset_collection, _from, state) do
    http_delete("#{state.url}/collections/#{state.collection}")

    result = http_put("#{state.url}/collections/#{state.collection}", collection_schema())

    {:reply, result, state}
  end

  def handle_call({:count_points, filter}, _from, state) do
    body = if filter, do: %{"filter" => filter, "exact" => true}, else: %{"exact" => true}
    result = http_post("#{state.url}/collections/#{state.collection}/points/count", body)
    {:reply, result, state}
  end

  # HTTP helpers — all calls have explicit timeouts and safe JSON decoding
  defp http_opts, do: [timeout: @http_timeout, recv_timeout: @http_timeout]

  defp http_get_raw(url) do
    case HTTPoison.get(url, [], http_opts()) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        {:error, {code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_get(url) do
    case HTTPoison.get(url, [], http_opts()) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        json_decode(body)

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        {:error, {code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_put(url, payload) do
    case Jason.encode(payload) do
      {:ok, body} ->
        case HTTPoison.put(url, body, [{"Content-Type", "application/json"}], http_opts()) do
          {:ok, %HTTPoison.Response{status_code: code, body: response}} when code in [200, 201] ->
            json_decode(response)

          {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
            {:error, {code, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:json_encode, reason}}
    end
  end

  defp http_delete(url) do
    case HTTPoison.delete(url, [], http_opts()) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        json_decode(body)

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        {:error, {code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_post(url, payload) do
    case Jason.encode(payload) do
      {:ok, body} ->
        case HTTPoison.post(url, body, [{"Content-Type", "application/json"}], http_opts()) do
          {:ok, %HTTPoison.Response{status_code: code, body: response}} when code in [200, 201] ->
            json_decode(response)

          {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
            {:error, {code, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:json_encode, reason}}
    end
  end

  defp json_decode(body) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end
end
