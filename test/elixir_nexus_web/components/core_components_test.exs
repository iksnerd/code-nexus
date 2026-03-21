defmodule ElixirNexusWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias ElixirNexusWeb.CoreComponents

  describe "stat_card/1" do
    test "renders with required attrs" do
      html = render_component(&CoreComponents.stat_card/1, label: "Files", value: "42")
      assert html =~ "Files"
      assert html =~ "42"
    end

    test "renders with white color fallback" do
      html = render_component(&CoreComponents.stat_card/1, label: "Test", value: "0", color: "white")
      assert html =~ "text-white"
    end

    test "renders with subtitle" do
      html = render_component(&CoreComponents.stat_card/1, label: "Files", value: "42", subtitle: "indexed")
      assert html =~ "indexed"
    end

    test "renders with animated counter" do
      html = render_component(&CoreComponents.stat_card/1, label: "Total Files", value: "99", animated: true)
      assert html =~ "AnimatedCounter"
      assert html =~ "stat-total-files"
    end
  end

  describe "entity_badge/1" do
    test "renders module badge" do
      html = render_component(&CoreComponents.entity_badge/1, type: "module")
      assert html =~ "module"
    end

    test "renders function badge" do
      html = render_component(&CoreComponents.entity_badge/1, type: "function")
      assert html =~ "function"
    end

    test "renders macro badge" do
      html = render_component(&CoreComponents.entity_badge/1, type: "macro")
      assert html =~ "macro"
      assert html =~ "amber"
    end

    test "renders struct badge" do
      html = render_component(&CoreComponents.entity_badge/1, type: "struct")
      assert html =~ "struct"
      assert html =~ "emerald"
    end

    test "renders unknown type with fallback classes" do
      html = render_component(&CoreComponents.entity_badge/1, type: "unknown")
      assert html =~ "unknown"
      assert html =~ "bg-slate-700"
    end
  end

  describe "status_indicator/1" do
    test "renders ready status" do
      html = render_component(&CoreComponents.status_indicator/1, status: "ready")
      assert html =~ "ready"
    end

    test "renders indexing status" do
      html = render_component(&CoreComponents.status_indicator/1, status: "indexing")
      assert html =~ "indexing"
    end

    test "renders error status" do
      html = render_component(&CoreComponents.status_indicator/1, status: "error")
      assert html =~ "error"
      assert html =~ "red"
    end

    test "renders unknown status with fallback" do
      html = render_component(&CoreComponents.status_indicator/1, status: "unknown")
      assert html =~ "unknown"
      assert html =~ "slate"
    end
  end

  describe "language_badge/1" do
    test "renders elixir badge" do
      html = render_component(&CoreComponents.language_badge/1, language: "elixir")
      assert html =~ "elixir"
    end

    test "renders javascript badge" do
      html = render_component(&CoreComponents.language_badge/1, language: "javascript")
      assert html =~ "javascript"
      assert html =~ "yellow"
    end

    test "renders python badge" do
      html = render_component(&CoreComponents.language_badge/1, language: "python")
      assert html =~ "python"
      assert html =~ "green"
    end

    test "renders go badge" do
      html = render_component(&CoreComponents.language_badge/1, language: "go")
      assert html =~ "go"
      assert html =~ "cyan"
    end

    test "renders unknown language with fallback" do
      html = render_component(&CoreComponents.language_badge/1, language: "unknown")
      assert html =~ "unknown"
      assert html =~ "bg-slate-700"
    end
  end

  describe "activity_item/1" do
    test "renders indexing_complete event" do
      event = %{type: :indexing_complete, message: "Done indexing", time: "12:00"}
      html = render_component(&CoreComponents.activity_item/1, event: event)
      assert html =~ "Done indexing"
      assert html =~ "●"
      assert html =~ "emerald"
    end

    test "renders file_reindexed event" do
      event = %{type: :file_reindexed, message: "Reindexed file.ex", time: "12:01"}
      html = render_component(&CoreComponents.activity_item/1, event: event)
      assert html =~ "↻"
      assert html =~ "blue"
    end

    test "renders synced event" do
      event = %{type: :synced, message: "Synced from Qdrant", time: "12:02"}
      html = render_component(&CoreComponents.activity_item/1, event: event)
      assert html =~ "⇄"
      assert html =~ "cyan"
    end

    test "renders unknown event type with fallback" do
      event = %{type: :unknown, message: "Something happened", time: "12:03"}
      html = render_component(&CoreComponents.activity_item/1, event: event)
      assert html =~ "•"
      assert html =~ "text-slate-400"
    end
  end

  describe "error_panel/1" do
    test "renders with empty errors" do
      html = render_component(&CoreComponents.error_panel/1, errors: [], expanded: false)
      assert is_binary(html)
    end

    test "renders with errors expanded" do
      html = render_component(&CoreComponents.error_panel/1, errors: ["Error 1", "Error 2"], expanded: true)
      assert html =~ "Error 1"
    end

    test "renders collapsed state with errors" do
      html = render_component(&CoreComponents.error_panel/1, errors: ["err1"], expanded: false)
      assert html =~ "▶"
      # The collapsed panel shows the count badge but not the error details
      assert html =~ "1"
    end
  end
end
