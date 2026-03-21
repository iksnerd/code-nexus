defmodule ElixirNexusWeb.CoreComponents do
  @moduledoc "Shared UI components for the ElixirNexus dashboard."
  use Phoenix.Component

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :color, :string, default: "blue"
  attr :subtitle, :string, default: nil
  attr :animated, :boolean, default: false

  def stat_card(assigns) do
    ~H"""
    <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-5 hover:border-slate-600/50 transition">
      <p class="text-slate-400 text-sm mb-1"><%= @label %></p>
      <p
        class={"text-3xl font-bold #{value_color(@color)}"}
        id={if @animated, do: "stat-#{String.replace(@label, " ", "-") |> String.downcase()}"}
        phx-hook={if @animated, do: "AnimatedCounter"}
        data-value={@value}
      >
        <%= @value %>
      </p>
      <%= if @subtitle do %>
        <p class="text-slate-500 text-xs mt-1"><%= @subtitle %></p>
      <% end %>
    </div>
    """
  end

  defp value_color("blue"), do: "text-blue-400"
  defp value_color("emerald"), do: "text-emerald-400"
  defp value_color("violet"), do: "text-violet-400"
  defp value_color("amber"), do: "text-amber-400"
  defp value_color("rose"), do: "text-rose-400"
  defp value_color(_), do: "text-white"

  attr :type, :string, required: true

  def entity_badge(assigns) do
    ~H"""
    <span class={"inline-block text-xs font-medium px-2 py-0.5 rounded-full #{badge_classes(@type)}"}>
      <%= @type %>
    </span>
    """
  end

  defp badge_classes("module"), do: "bg-purple-900/60 text-purple-300"
  defp badge_classes("function"), do: "bg-sky-900/60 text-sky-300"
  defp badge_classes("macro"), do: "bg-amber-900/60 text-amber-300"
  defp badge_classes("struct"), do: "bg-emerald-900/60 text-emerald-300"
  defp badge_classes(_), do: "bg-slate-700 text-slate-300"

  attr :status, :string, required: true

  def status_indicator(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <span class={"w-2 h-2 rounded-full #{dot_classes(@status)}"}></span>
      <span class={"text-xs font-medium #{text_classes(@status)}"}><%= @status %></span>
    </span>
    """
  end

  defp dot_classes("ready"), do: "bg-emerald-400"
  defp dot_classes("indexing"), do: "bg-amber-400 animate-pulse-dot"
  defp dot_classes("error"), do: "bg-red-400"
  defp dot_classes(_), do: "bg-slate-400"

  defp text_classes("ready"), do: "text-emerald-400"
  defp text_classes("indexing"), do: "text-amber-400"
  defp text_classes("error"), do: "text-red-400"
  defp text_classes(_), do: "text-slate-400"

  attr :language, :string, required: true

  def language_badge(assigns) do
    ~H"""
    <span class={"inline-block text-xs font-medium px-2 py-0.5 rounded #{lang_classes(@language)}"}>
      <%= @language %>
    </span>
    """
  end

  defp lang_classes("elixir"), do: "bg-purple-900/50 text-purple-300"
  defp lang_classes("javascript"), do: "bg-yellow-900/50 text-yellow-300"
  defp lang_classes("typescript"), do: "bg-blue-900/50 text-blue-300"
  defp lang_classes("python"), do: "bg-green-900/50 text-green-300"
  defp lang_classes("go"), do: "bg-cyan-900/50 text-cyan-300"
  defp lang_classes("rust"), do: "bg-orange-900/50 text-orange-300"
  defp lang_classes("ruby"), do: "bg-red-900/50 text-red-300"
  defp lang_classes("java"), do: "bg-red-900/50 text-red-200"
  defp lang_classes(_), do: "bg-slate-700 text-slate-300"

  attr :event, :map, required: true

  def activity_item(assigns) do
    ~H"""
    <div class="flex items-start gap-3 py-2 border-b border-slate-800/50 last:border-0">
      <span class={"mt-0.5 text-xs #{activity_icon_color(@event.type)}"}><%= activity_icon(@event.type) %></span>
      <div class="flex-1 min-w-0">
        <p class="text-sm text-slate-300 truncate"><%= @event.message %></p>
        <p class="text-xs text-slate-500"><%= @event.time %></p>
      </div>
    </div>
    """
  end

  defp activity_icon(:indexing_complete), do: "●"
  defp activity_icon(:indexing_progress), do: "◐"
  defp activity_icon(:file_reindexed), do: "↻"
  defp activity_icon(:collection_changed), do: "⬡"
  defp activity_icon(:synced), do: "⇄"
  defp activity_icon(_), do: "•"

  defp activity_icon_color(:indexing_complete), do: "text-emerald-400"
  defp activity_icon_color(:indexing_progress), do: "text-amber-400"
  defp activity_icon_color(:file_reindexed), do: "text-blue-400"
  defp activity_icon_color(:collection_changed), do: "text-violet-400"
  defp activity_icon_color(:synced), do: "text-cyan-400"
  defp activity_icon_color(_), do: "text-slate-400"

  attr :errors, :list, required: true
  attr :expanded, :boolean, default: false

  def error_panel(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div class="bg-red-950/30 border border-red-900/50 rounded-xl overflow-hidden">
        <button
          phx-click="toggle_errors"
          class="w-full flex items-center justify-between px-5 py-3 hover:bg-red-950/50 transition"
        >
          <span class="flex items-center gap-2">
            <span class="text-red-400 font-medium text-sm">Errors</span>
            <span class="bg-red-600 text-white text-xs font-bold px-2 py-0.5 rounded-full"><%= length(@errors) %></span>
          </span>
          <span class="text-red-400 text-xs"><%= if @expanded, do: "▼", else: "▶" %></span>
        </button>
        <%= if @expanded do %>
          <div class="border-t border-red-900/50 px-5 py-3 space-y-2 max-h-48 overflow-y-auto">
            <%= for error <- @errors do %>
              <p class="text-red-300 text-xs font-mono"><%= inspect(error) %></p>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end
end
