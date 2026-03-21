defmodule ElixirNexus.API.SearchController do
  use Phoenix.Controller

  def search(conn, %{"query" => query, "limit" => limit}) do
    {:ok, results} = ElixirNexus.Search.search_code(query, limit)
    json(conn, %{success: true, data: results})
  end

  def search(conn, %{"query" => query}) do
    {:ok, results} = ElixirNexus.Search.search_code(query, 10)
    json(conn, %{success: true, data: results})
  end

  def callees(conn, %{"entity_name" => name, "limit" => limit}) do
    case ElixirNexus.Search.find_callees(name, limit) do
      {:ok, results} ->
        json(conn, %{success: true, data: results})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def callees(conn, %{"entity_name" => name}) do
    case ElixirNexus.Search.find_callees(name, 20) do
      {:ok, results} ->
        json(conn, %{success: true, data: results})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def index(conn, %{"path" => path}) do
    case ElixirNexus.Indexer.index_directory(path) do
      {:ok, status} ->
        json(conn, %{success: true, data: status})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end
end
