defmodule Mix.Tasks.Index do
  use Mix.Task

  @shortdoc "Index a directory or file"

  @moduledoc """
  Index a directory or file and store embeddings in Qdrant.

  Usage:
    mix index <path>           # Index a directory or file
    mix index --status         # Get indexing status
  """

  def run(args) do
    Mix.Task.run("app.start")
    
    # Give services time to start
    Process.sleep(2000)

    case args do
      ["--status"] ->
        status = ElixirNexus.Indexer.status()
        IO.inspect(status, label: "Indexer Status")

      [path] ->
        path = Path.expand(path)
        
        case File.dir?(path) do
          true ->
            IO.puts("📁 Indexing directory: #{path}")

            case ElixirNexus.Indexer.index_directory(path) do
              {:ok, state} ->
                IO.puts("✅ Indexing complete!")
                num_files = MapSet.size(state.indexed_files)
                IO.puts("   Files indexed: #{num_files}")
                IO.puts("   Total chunks: #{state.total_chunks}")
                if state.errors != [], do: IO.puts("   Errors: #{length(state.errors)}")

              {:error, reason} ->
                IO.puts("❌ Indexing failed: #{inspect(reason)}")
            end

          false ->
            IO.puts("📄 Indexing file: #{path}")

            case ElixirNexus.Indexer.index_file(path) do
              {:ok, chunks} ->
                IO.puts("✅ File indexed! #{length(chunks)} chunks created")

              {:error, reason} ->
                IO.puts("❌ Indexing failed: #{inspect(reason)}")
            end
        end

      _ ->
        IO.puts("Usage:")
        IO.puts("  mix index <path>           # Index a directory or file")
        IO.puts("  mix index --status         # Get indexing status")
        IO.puts("\nExample:")
        IO.puts("  mix index lib/")
    end
  end
end
