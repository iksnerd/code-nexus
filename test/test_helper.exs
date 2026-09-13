ExUnit.start(exclude: [:performance])

# Configure test environment
Application.put_env(:elixir_nexus, :env, :test)

# Load Mox definitions
Code.require_file("support/mox_setup.ex", __DIR__)

# Sweep every collection the suite creates. Tests share the dev Qdrant with real
# projects, so match only names the suite generates — never a broad "_test"
# pattern that could delete a real project collection. The unsuffixed
# `mcp_autoreindex` form also catches runs from before those dirs were renamed.
suite_collection? = fn name ->
  name == ElixirNexus.QdrantClient.collection_name() or
    name in ~w(nexus_force_switched nexus_temp_collection nexus_ensure_collection_test nexus_test_sizes_temp) or
    Regex.match?(~r/^nexus_mcp_(reindex_test|lib_test|autoreindex_test|autoreindex)_\d+$/, name)
end

ExUnit.after_suite(fn _results ->
  case ElixirNexus.QdrantClient.list_collections() do
    {:ok, names} ->
      names
      |> Enum.filter(suite_collection?)
      |> Enum.each(&ElixirNexus.QdrantClient.delete_collection/1)

    {:error, _} ->
      :ok
  end
end)
