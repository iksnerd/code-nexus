defmodule ElixirNexus.IndexingProducer do
  @moduledoc """
  GenStage producer that buffers file paths for the Broadway indexing pipeline.
  Started by Broadway (not directly in the supervision tree).
  Stores its PID in :persistent_term so callers can push messages.
  """
  use GenStage
  require Logger

  @registry ElixirNexus.Registry

  @doc "Push file paths into the producer buffer. Returns :ok or {:error, :producer_not_available}."
  def push(file_paths) when is_list(file_paths) do
    case producer_pid() do
      pid when is_pid(pid) ->
        send(pid, {:push, file_paths})
        :ok

      nil ->
        Logger.warning("IndexingProducer not started, dropping #{length(file_paths)} files")
        {:error, :producer_not_available}
    end
  end

  defp producer_pid do
    case Registry.lookup(@registry, __MODULE__) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(_opts) do
    Registry.register(@registry, __MODULE__, :producer)
    Logger.info("IndexingProducer started")
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    {events, new_state} = dispatch(%{state | demand: state.demand + incoming_demand})
    {:noreply, events, new_state}
  end

  @impl true
  def handle_info({:push, file_paths}, state) do
    queue = Enum.reduce(file_paths, state.queue, &:queue.in/2)
    {events, new_state} = dispatch(%{state | queue: queue})
    {:noreply, events, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  defp dispatch(state) do
    {events, remaining_queue, remaining_demand} =
      take_from_queue(state.queue, state.demand, [])

    {Enum.reverse(events), %{state | queue: remaining_queue, demand: remaining_demand}}
  end

  defp take_from_queue(queue, 0, acc), do: {acc, queue, 0}

  defp take_from_queue(queue, demand, acc) do
    case :queue.out(queue) do
      {{:value, item}, new_queue} ->
        take_from_queue(new_queue, demand - 1, [item | acc])

      {:empty, queue} ->
        {acc, queue, demand}
    end
  end
end
