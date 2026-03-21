defmodule ElixirNexus.Chunker do
  @moduledoc """
  Splits code into semantic chunks (functions, modules, etc.).
  Each chunk becomes an embeddings candidate.
  """

  def chunk_entities(entities) when is_list(entities) do
    entities
    |> Enum.flat_map(&chunk_entity/1)
  end

  @doc """
  Convert a CodeSchema entity into one or more chunks.
  A single function = one chunk. A module = multiple chunks (one per function + one for module itself).
  """
  def chunk_entity(%ElixirNexus.CodeSchema{} = entity) do
    [
      %{
        id: generate_id(entity),
        entity_type: entity.entity_type,
        name: entity.name,
        file_path: entity.file_path,
        content: entity.content,
        start_line: entity.start_line,
        end_line: entity.end_line,
        docstring: entity.docstring,
        module_path: entity.module_path,
        visibility: entity.visibility,
        parameters: entity.parameters,
        calls: entity.calls,
        is_a: entity.is_a,
        contains: entity.contains
      }
    ]
  end

  @doc """
  Prepare chunk for dense embedding. Combines content with context.
  """
  def prepare_for_embedding(%{} = chunk) do
    context = [
      "File: #{chunk.file_path}",
      "Type: #{chunk.entity_type}",
      "Name: #{chunk.name}"
    ]

    context_str = Enum.join(context, "\n")
    "#{context_str}\n\n#{chunk.content}"
  end

  @doc """
  Prepare chunk for sparse keyword vector. Heavily weights the entity name
  so exact name queries rank higher than tangentially related modules.
  """
  def prepare_for_keywords(%{} = chunk) do
    name = chunk.name || ""
    # Repeat name 3x to boost keyword weight for name matches
    name_boost = String.duplicate("#{name} ", 3)
    params = Enum.join(chunk.parameters || [], " ")
    calls = Enum.join(chunk.calls || [], " ")
    "#{name_boost}#{params} #{calls} #{chunk.content}"
  end

  defp generate_id(%ElixirNexus.CodeSchema{} = entity) do
    content = "#{entity.file_path}:#{entity.entity_type}:#{entity.name}:#{entity.start_line}"
    :crypto.hash(:sha256, content) |> Base.encode16() |> String.downcase()
  end
end
