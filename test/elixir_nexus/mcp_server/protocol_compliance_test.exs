defmodule ElixirNexus.MCPServer.ProtocolComplianceTest do
  # Runs requests through ExMCP's MessageProcessor, the same path the HTTP
  # transport uses, so these catch responses a spec-validating client
  # (Claude Code) would reject.
  use ExUnit.Case, async: false

  alias ElixirNexus.MCPServer

  defp process(method, params \\ %{}) do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    request
    |> ExMCP.MessageProcessor.new(transport: :http)
    |> ExMCP.MessageProcessor.process(%{handler: MCPServer, server_info: %{}})
    |> Map.fetch!(:response)
  end

  describe "concurrent requests" do
    test "all succeed instead of colliding on the per-request server instance" do
      # The HTTP transport starts a temporary server per request. When that
      # instance registered the global module name, only one request could run
      # at a time; the rest failed with "Failed to start server instance". A
      # client connecting (tools/list + resources/list in parallel) or a second
      # session hit this constantly.
      methods = List.duplicate("tools/list", 10) ++ List.duplicate("resources/list", 10)

      responses =
        methods
        |> Task.async_stream(&process/1, max_concurrency: 20, ordered: false, timeout: 15_000)
        |> Enum.map(fn {:ok, response} -> response end)

      errors = Enum.filter(responses, &Map.has_key?(&1, "error"))
      assert errors == [], "#{length(errors)} of #{length(responses)} failed: #{inspect(hd(errors ++ [nil]))}"
    end
  end

  describe "unknown methods" do
    test "get a JSON-RPC method-not-found error instead of no response" do
      # Claude Code probes server/discover (protocol 2026-07-28) on connect. With
      # no response the HTTP plug answered HTTP 500 "no response from handler".
      for method <- ["server/discover", "made/up"] do
        assert %{"error" => %{"code" => -32_601}, "id" => 1} = process(method)
      end
    end

    test "notifications still get {:noreply, state}" do
      # ExMCP's notification cast path only matches {:noreply, state}.
      assert {:noreply, %{}} = MCPServer.handle_request("notifications/roots/list_changed", %{}, %{})
    end
  end

  describe "resources/list" do
    test "every resource uses spec field names and has no null values" do
      %{"result" => %{"resources" => resources}} = process("resources/list")
      assert resources != []

      for resource <- resources do
        json = resource |> Jason.encode!() |> Jason.decode!()

        refute Enum.any?(json, fn {_k, v} -> is_nil(v) end), "null field in #{inspect(json)}"
        assert is_binary(json["uri"]) and is_binary(json["name"])
        assert json["mimeType"] == "text/markdown"
        refute Map.has_key?(json, "mime_type")
        refute Map.has_key?(json, "list_pattern")
      end
    end

    test "resources capability still initializes" do
      assert %{"result" => %{"capabilities" => %{"resources" => _}}} =
               process("initialize", %{
                 "protocolVersion" => "2025-06-18",
                 "capabilities" => %{},
                 "clientInfo" => %{"name" => "test", "version" => "0"}
               })
    end
  end
end
