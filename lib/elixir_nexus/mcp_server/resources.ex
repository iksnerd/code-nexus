defmodule ElixirNexus.MCPServer.Resources do
  @moduledoc "MCP resource content generation — tool guide, project overview, architecture, hotspots."

  @doc "Dispatch a resource URI to its content generator."
  def read_resource_content("nexus://guide/tools"), do: {:ok, generate_tool_guide()}
  def read_resource_content("nexus://project/overview"), do: {:ok, generate_overview()}
  def read_resource_content("nexus://project/architecture"), do: {:ok, generate_architecture()}
  def read_resource_content("nexus://project/hotspots"), do: {:ok, generate_hotspots()}
  def read_resource_content(uri), do: {:error, "Unknown resource: #{uri}"}

  defp indexed? do
    ElixirNexus.ChunkCache.count() > 0
  end

  defp not_indexed_message do
    """
    # No Project Indexed Yet

    Run the `reindex` tool first to build the code index and call graph, then read this resource again.

    **Quick start:**
    1. Call `reindex` with your project path
    2. Call `load_resources` or read `nexus://guide/tools` for usage tips
    3. Call `get_graph_stats` to see what was indexed
    """
    |> String.trim()
  end

  defp generate_tool_guide do
    """
    # CodeNexus Tool Guide

    ## Recommended Workflow

    1. **`reindex`** — Always run first. Parses source files, builds the call graph and search index. Run again after code changes.
    2. **`get_graph_stats`** — Orient yourself. See language breakdown, entity counts, top connected modules.
    3. **Targeted queries** — Use the right tool for your question (see below).

    ## When to Use Each Tool

    | Question | Tool |
    |----------|------|
    | "What does X do?" / "Find code related to Y" | `search_code` |
    | "What does this function call?" | `find_all_callees` |
    | "Who calls this function?" | `find_all_callers` |
    | "What breaks if I change this?" | `analyze_impact` |
    | "What files are related to this file?" | `get_community_context` |
    | "What's the module structure?" | `find_module_hierarchy` |
    | "Any unused public functions?" | `find_dead_code` |
    | "Codebase overview" | `get_graph_stats` |

    ## Query Tips

    - **`search_code`**: Use natural language ("error handling in HTTP client") or exact names. Hybrid semantic + keyword ranking.
    - **`find_all_callers` / `find_all_callees`**: Use exact function names. Case-insensitive, supports short names (e.g. `embed_batch` matches `ElixirNexus.EmbeddingModel.embed_batch`).
    - **`analyze_impact`**: Set `depth` (default 3) to control how many levels of transitive callers to traverse. Higher depth = wider blast radius.
    - **`get_community_context`**: Pass a file path to find structurally coupled files — great for understanding what else to review.

    ## Common Patterns

    - **Before refactoring a function**: `analyze_impact` → `find_all_callers` → review each caller
    - **Understanding a new module**: `find_module_hierarchy` → `get_community_context` on its file → `search_code` for usage patterns
    - **Finding dead code to clean up**: `find_dead_code` with optional `path_prefix` to scope
    - **Exploring unfamiliar code**: `get_graph_stats` → `search_code` with intent-based queries → drill into results with `find_all_callees`
    """
    |> String.trim()
  end

  defp generate_overview do
    if not indexed?() do
      not_indexed_message()
    else
      chunks = ElixirNexus.ChunkCache.all()
      nodes = ElixirNexus.GraphCache.all_nodes()

      file_count = chunks |> Enum.map(& &1.file_path) |> Enum.uniq() |> length()

      lang_counts =
        chunks
        |> Enum.group_by(& &1.language)
        |> Enum.map(fn {lang, items} -> {lang || "unknown", length(items)} end)
        |> Enum.sort_by(fn {_lang, count} -> -count end)

      entity_types =
        nodes
        |> Map.values()
        |> Enum.group_by(fn node -> node["entity_type"] || "unknown" end)
        |> Enum.map(fn {type, items} -> {type, length(items)} end)
        |> Enum.sort_by(fn {_type, count} -> -count end)

      project_path =
        Application.get_env(:elixir_nexus, :current_project_path) || "(unknown)"

      lang_table =
        lang_counts
        |> Enum.map(fn {lang, count} -> "| #{lang} | #{count} |" end)
        |> Enum.join("\n")

      entity_table =
        entity_types
        |> Enum.map(fn {type, count} -> "| #{type} | #{count} |" end)
        |> Enum.join("\n")

      """
      # Project Overview

      **Project:** #{project_path}
      **Files indexed:** #{file_count}
      **Total chunks:** #{length(chunks)}
      **Graph nodes:** #{map_size(nodes)}

      ## Language Breakdown

      | Language | Chunks |
      |----------|--------|
      #{lang_table}

      ## Entity Types

      | Type | Count |
      |------|-------|
      #{entity_table}
      """
      |> String.trim()
    end
  end

  defp generate_architecture do
    if not indexed?() do
      not_indexed_message()
    else
      nodes = ElixirNexus.GraphCache.all_nodes()
      node_list = Map.values(nodes)

      modules =
        node_list
        |> Enum.filter(fn n -> n["entity_type"] == "module" end)
        |> Enum.map(fn mod ->
          calls_out = length(mod["calls"] || [])
          children = length(mod["contains"] || [])
          parents = length(mod["is_a"] || [])
          %{name: mod["name"], file: mod["file_path"], calls_out: calls_out, children: children, parents: parents}
        end)
        |> Enum.sort_by(fn m -> -(m.calls_out + m.children) end)

      total_modules = length(modules)
      shown = Enum.take(modules, 20)

      module_table =
        shown
        |> Enum.map(fn m ->
          "| #{m.name} | #{m.children} | #{m.calls_out} | #{m.file} |"
        end)
        |> Enum.join("\n")

      truncation_note =
        if total_modules > 20,
          do: "\n\n*Showing top 20 of #{total_modules} modules (sorted by connectivity).*",
          else: ""

      # Top connected non-module entities (functions/classes)
      top_connected =
        node_list
        |> Enum.reject(fn n -> n["entity_type"] == "module" end)
        |> Enum.map(fn n ->
          %{name: n["name"], type: n["entity_type"], calls: length(n["calls"] || []), file: n["file_path"]}
        end)
        |> Enum.sort_by(fn n -> -n.calls end)
        |> Enum.take(10)

      connected_table =
        top_connected
        |> Enum.map(fn n -> "| #{n.name} | #{n.type} | #{n.calls} | #{n.file} |" end)
        |> Enum.join("\n")

      """
      # Project Architecture

      **Total modules:** #{total_modules}
      **Total graph nodes:** #{map_size(nodes)}

      ## Key Modules

      | Module | Children | Outgoing Calls | File |
      |--------|----------|----------------|------|
      #{module_table}#{truncation_note}

      ## Most Connected Functions

      | Name | Type | Outgoing Calls | File |
      |------|------|----------------|------|
      #{connected_table}
      """
      |> String.trim()
    end
  end

  defp generate_hotspots do
    if not indexed?() do
      not_indexed_message()
    else
      nodes = ElixirNexus.GraphCache.all_nodes()
      node_list = Map.values(nodes)

      # Fan-out: entities with the most outgoing calls
      top_fan_out =
        node_list
        |> Enum.map(fn n ->
          %{name: n["name"], type: n["entity_type"], fan_out: length(n["calls"] || []), file: n["file_path"]}
        end)
        |> Enum.sort_by(fn n -> -n.fan_out end)
        |> Enum.take(15)

      # Fan-in: count how many times each name appears as a callee
      callee_counts =
        node_list
        |> Enum.flat_map(fn n -> n["calls"] || [] end)
        |> Enum.frequencies()

      top_fan_in =
        callee_counts
        |> Enum.sort_by(fn {_name, count} -> -count end)
        |> Enum.take(15)

      # Dead code count
      public_nodes =
        node_list
        |> Enum.filter(fn n ->
          n["visibility"] == "public" and n["entity_type"] != "module"
        end)

      called_names = MapSet.new(Map.keys(callee_counts))

      dead_count =
        public_nodes
        |> Enum.reject(fn n ->
          name = n["name"] || ""
          short = name |> String.split(".") |> List.last() || ""
          MapSet.member?(called_names, name) or MapSet.member?(called_names, short)
        end)
        |> length()

      fan_out_table =
        top_fan_out
        |> Enum.map(fn n -> "| #{n.name} | #{n.type} | #{n.fan_out} | #{n.file} |" end)
        |> Enum.join("\n")

      fan_in_table =
        top_fan_in
        |> Enum.map(fn {name, count} -> "| #{name} | #{count} |" end)
        |> Enum.join("\n")

      """
      # Complexity Hotspots

      ## Highest Fan-Out (most outgoing calls)

      | Name | Type | Calls Out | File |
      |------|------|-----------|------|
      #{fan_out_table}

      ## Highest Fan-In (most callers)

      | Name | Caller Count |
      |------|-------------|
      #{fan_in_table}

      ## Dead Code Summary

      **Public functions with zero callers:** #{dead_count} of #{length(public_nodes)} public entities
      """
      |> String.trim()
    end
  end
end
