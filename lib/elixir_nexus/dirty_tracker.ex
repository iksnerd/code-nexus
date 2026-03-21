defmodule ElixirNexus.DirtyTracker do
  use GenServer
  require Logger

  @moduledoc """
  Tracks file changes using checksums.
  Enables incremental indexing: only re-parse files that have changed.
  """

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a file is dirty (has changed since last index).
  Returns {is_dirty, current_checksum}
  """
  def is_dirty?(file_path) do
    GenServer.call(__MODULE__, {:is_dirty, file_path})
  end

  @doc """
  Mark a file as clean (update its checksum).
  """
  def mark_clean(file_path) do
    GenServer.call(__MODULE__, {:mark_clean, file_path})
  end

  @doc """
  Get all dirty files in a directory.
  """
  def get_dirty_files(directory) do
    GenServer.call(__MODULE__, {:get_dirty_files, directory})
  end

  @doc """
  Clear all checksums (full re-index).
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    Logger.info("DirtyTracker started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:is_dirty, file_path}, _from, state) do
    case File.read(file_path) do
      {:ok, content} ->
        current_checksum = :crypto.hash(:sha256, content) |> Base.encode16()
        stored_checksum = Map.get(state, file_path)

        is_dirty = stored_checksum != current_checksum

        {:reply, {is_dirty, current_checksum}, state}

      {:error, reason} ->
        Logger.error("Failed to read file #{file_path}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_clean, file_path}, _from, state) do
    case File.read(file_path) do
      {:ok, content} ->
        checksum = :crypto.hash(:sha256, content) |> Base.encode16()
        new_state = Map.put(state, file_path, checksum)
        Logger.debug("Marked clean: #{file_path}")
        {:reply, {:ok, checksum}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @indexable_extensions ~w(.ex .exs .js .jsx .ts .tsx .py .go .rs .java .rb)

  def handle_call({:get_dirty_files, directory}, _from, state) do
    case File.ls(directory) do
      {:ok, files} ->
        dirty_files =
          files
          |> Enum.filter(fn f -> Path.extname(f) in @indexable_extensions end)
          |> Enum.map(&Path.join(directory, &1))
          |> Enum.filter(fn path ->
            case File.read(path) do
              {:ok, content} ->
                current_checksum = :crypto.hash(:sha256, content) |> Base.encode16()
                stored_checksum = Map.get(state, path)
                stored_checksum != current_checksum

              {:error, _} ->
                false
            end
          end)

        {:reply, {:ok, dirty_files}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset, _from, _state) do
    Logger.info("DirtyTracker reset: all files marked for re-indexing")
    {:reply, :ok, %{}}
  end
end
