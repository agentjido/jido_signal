defmodule Jido.Signal.SanitizerTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Sanitizer

  describe "sanitize/2" do
    test "redacts sensitive keys for telemetry" do
      sanitized =
        Sanitizer.sanitize(
          %{
            password: "super-secret",
            nested: %{token: "abc123"},
            safe: "value"
          },
          :telemetry
        )

      assert sanitized.password == "[REDACTED]"
      assert sanitized.nested.token == "[REDACTED]"
      assert sanitized.safe == "value"
    end

    test "serializes tuples and structs for transport" do
      {:ok, signal} =
        Signal.new(%{
          type: "user.created",
          source: "/auth",
          data: %{name: "Ada", password: "hidden"}
        })

      sanitized = Sanitizer.sanitize(%{signal: signal, value: {:ok, :accepted}}, :transport)

      assert sanitized["signal"]["__struct__"] == "Jido.Signal"
      assert sanitized["signal"]["data"]["password"] == "[REDACTED]"
      assert sanitized["value"] == %{"__type__" => "tuple", "items" => ["ok", "accepted"]}
    end
  end

  describe "preview/3" do
    test "returns a bounded inspect-safe preview" do
      preview =
        Sanitizer.preview(%{payload: String.duplicate("a", 400)}, :telemetry, max_length: 60)

      assert String.length(preview) <= 63
      assert String.ends_with?(preview, "...")
    end
  end
end
