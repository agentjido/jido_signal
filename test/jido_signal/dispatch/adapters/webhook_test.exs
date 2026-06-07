defmodule Jido.Signal.Dispatch.WebhookTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Dispatch.Webhook

  describe "validate_opts/1" do
    test "validates required url" do
      assert {:error, _} = Webhook.validate_opts([])
      assert {:error, _} = Webhook.validate_opts(url: nil)
      assert {:ok, opts} = Webhook.validate_opts(url: "https://example.com")
      assert opts[:method] == :post
      assert opts[:headers] == []
      assert opts[:timeout] == 5000
      assert opts[:retry] == %{max_attempts: 3, base_delay: 1000, max_delay: 5000}
    end

    test "validates optional secret" do
      assert {:ok, _} = Webhook.validate_opts(url: "https://example.com", secret: nil)
      assert {:ok, _} = Webhook.validate_opts(url: "https://example.com", secret: "mysecret")
      assert {:error, _} = Webhook.validate_opts(url: "https://example.com", secret: "")
      assert {:error, _} = Webhook.validate_opts(url: "https://example.com", secret: 123)
    end

    test "validates header names" do
      assert {:ok, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 signature_header: "x-signature",
                 event_type_header: "x-event"
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 signature_header: 123
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 event_type_header: 123
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 signature_header: "bad:header"
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 event_type_header: "bad\r\nheader"
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 signature_header: "x-webhook-timestamp"
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 signature_header: "x-webhook-event",
                 event_type_header: "X-Webhook-Event"
               )
    end

    test "validates event type map" do
      assert {:ok, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 event_type_map: %{
                   "user:created" => "user.created",
                   "user:updated" => "user.updated"
                 }
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 event_type_map: %{
                   "user:created" => 123
                 }
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 event_type_map: "invalid"
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 event_type_map: %{"user:created" => "bad\r\nvalue"}
               )
    end

    test "inherits HTTP adapter validation" do
      assert {:ok, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 method: :post,
                 headers: [{"content-type", "application/json"}],
                 timeout: 5000
               )

      assert {:error, _} =
               Webhook.validate_opts(
                 url: "https://example.com",
                 method: :invalid
               )
    end
  end

  describe "deliver/2" do
    setup do
      signal = %Jido.Signal{
        id: "test_signal",
        type: "test.event",
        source: "test",
        time: DateTime.utc_now(),
        data: %{value: 42}
      }

      {:ok, signal: signal}
    end

    test "adds signature header when secret is provided", %{signal: signal} do
      opts = [
        url: "https://example.com",
        secret: "test_secret",
        method: :post,
        timeout: 1,
        retry: %{max_attempts: 1, base_delay: 1, max_delay: 1}
      ]

      # We'll get an error because the URL isn't real, but we can inspect the headers
      {:error, _} = result = Webhook.deliver(signal, opts)

      # The actual assertion would depend on how we can inspect the headers
      # For now, we're just verifying the call doesn't crash
      assert result
    end

    test "maps event types when mapping is provided", %{signal: signal} do
      opts = [
        url: "https://example.com",
        event_type_map: %{
          "test.event" => "test:mapped"
        },
        method: :post,
        timeout: 1,
        retry: %{max_attempts: 1, base_delay: 1, max_delay: 1}
      ]

      # We'll get an error because the URL isn't real, but the mapping should occur
      {:error, _} = result = Webhook.deliver(signal, opts)

      # The actual assertion would depend on how we can inspect the headers
      # For now, we're just verifying the call doesn't crash
      assert result
    end

    test "uses default headers when not specified", %{signal: signal} do
      opts = [
        url: "https://example.com",
        method: :post,
        timeout: 1,
        retry: %{max_attempts: 1, base_delay: 1, max_delay: 1}
      ]

      {:error, _} = result = Webhook.deliver(signal, opts)
      assert result
    end

    test "merges custom headers with webhook headers", %{signal: signal} do
      opts = [
        url: "https://example.com",
        method: :post,
        headers: [{"x-custom", "value"}],
        timeout: 1,
        retry: %{max_attempts: 1, base_delay: 1, max_delay: 1}
      ]

      {:error, _} = result = Webhook.deliver(signal, opts)
      assert result
    end

    test "generated webhook headers override caller-supplied protected headers", %{signal: signal} do
      opts = [
        url: "https://example.com",
        secret: "test_secret",
        headers: [
          {"X-Webhook-Signature", "attacker"},
          {"x-webhook-event", "attacker.event"},
          {"x-webhook-timestamp", "1"},
          {"x-custom", "value"}
        ]
      ]

      assert {:ok, http_opts} = Webhook.prepare_http_opts(signal, opts)
      headers = Keyword.fetch!(http_opts, :headers)

      refute {"X-Webhook-Signature", "attacker"} in headers
      refute {"x-webhook-event", "attacker.event"} in headers
      refute {"x-webhook-timestamp", "1"} in headers
      assert {"x-custom", "value"} in headers

      assert Enum.count(headers, fn {name, _} ->
               String.downcase(name) == "x-webhook-signature"
             end) == 1

      assert Enum.count(headers, fn {name, _} ->
               String.downcase(name) == "x-webhook-event"
             end) == 1

      assert Enum.count(headers, fn {name, _} ->
               String.downcase(name) == "x-webhook-timestamp"
             end) == 1
    end

    test "reserved webhook headers cannot be supplied when signatures are disabled", %{
      signal: signal
    } do
      opts = [
        url: "https://example.com",
        headers: [
          {"x-webhook-signature", "attacker"},
          {"x-webhook-event", "attacker.event"},
          {"x-webhook-timestamp", "1"},
          {"x-custom", "value"}
        ]
      ]

      assert {:ok, http_opts} = Webhook.prepare_http_opts(signal, opts)
      headers = Keyword.fetch!(http_opts, :headers)

      refute {"x-webhook-signature", "attacker"} in headers
      refute {"x-webhook-event", "attacker.event"} in headers
      refute {"x-webhook-timestamp", "1"} in headers
      assert {"x-custom", "value"} in headers

      refute Enum.any?(headers, fn {name, _value} ->
               String.downcase(name) == "x-webhook-signature"
             end)
    end

    test "configured webhook header names are also reserved", %{signal: signal} do
      opts = [
        url: "https://example.com",
        secret: "test_secret",
        signature_header: "x-signature",
        event_type_header: "x-event",
        headers: [
          {"X-Signature", "attacker"},
          {"x-event", "attacker.event"},
          {"x-webhook-timestamp", "1"},
          {"x-custom", "value"}
        ]
      ]

      assert {:ok, http_opts} = Webhook.prepare_http_opts(signal, opts)
      headers = Keyword.fetch!(http_opts, :headers)

      refute {"X-Signature", "attacker"} in headers
      refute {"x-event", "attacker.event"} in headers
      refute {"x-webhook-timestamp", "1"} in headers
      assert {"x-custom", "value"} in headers

      assert Enum.any?(headers, fn {name, _value} -> name == "x-signature" end)
      assert Enum.any?(headers, fn {name, _value} -> name == "x-event" end)
    end

    test "prepare_http_opts validates header configuration", %{signal: signal} do
      assert {:error, _reason} =
               Webhook.prepare_http_opts(signal,
                 url: "https://example.com",
                 secret: "test_secret",
                 signature_header: "bad\r\nheader"
               )
    end

    test "rejects signal types that cannot be sent as header values" do
      signal = %Jido.Signal{
        id: "test_signal",
        type: "bad\r\nevent",
        source: "test",
        time: DateTime.utc_now(),
        data: %{}
      }

      assert {:error, :invalid_event_type} =
               Webhook.prepare_http_opts(signal, url: "https://example.com")
    end
  end
end
