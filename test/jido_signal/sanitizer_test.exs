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

    test "redacts sensitive header tuple lists" do
      sanitized =
        Sanitizer.sanitize(
          [
            {"x-api-key", "api-secret"},
            {"authorization", "Bearer secret-token"},
            {"x-custom", "visible"}
          ],
          :telemetry
        )

      assert sanitized["x-api-key"] == "[REDACTED]"
      assert sanitized["authorization"] == "[REDACTED]"
      assert sanitized["x-custom"] == "visible"
    end

    test "keeps empty lists as lists" do
      assert Sanitizer.sanitize([], :telemetry) == []
      assert Sanitizer.sanitize([], :transport) == []
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

    test "removes URI credentials and query data" do
      uri = URI.parse("https://user:pass@example.com/path?token=secret#private")

      assert Sanitizer.sanitize(uri, :telemetry) == "https://example.com/path"
    end

    test "does not include exception messages" do
      sanitized = Sanitizer.sanitize(RuntimeError.exception("token=secret"), :telemetry)

      assert sanitized == %{module: "RuntimeError"}
      refute inspect(sanitized) =~ "secret"
    end

    test "keeps truncated transport text as valid UTF-8" do
      sanitized = Sanitizer.sanitize(String.duplicate("€", 600), :transport)

      assert String.valid?(sanitized)
      assert byte_size(sanitized) <= 1_027
    end

    test "bounds nested tuples" do
      nested = Enum.reduce(1..20, :value, fn _number, acc -> {acc} end)
      sanitized = Sanitizer.sanitize(nested, :telemetry)

      assert inspect(sanitized) =~ "summary"
      assert byte_size(:erlang.term_to_binary(sanitized)) < 1_000
    end
  end

  describe "preview/3" do
    test "returns a bounded inspect-safe preview" do
      preview =
        Sanitizer.preview(%{payload: String.duplicate("a", 400)}, :telemetry, max_length: 60)

      assert String.length(preview) <= 63
      assert String.ends_with?(preview, "...")
    end

    test "uses the default limit when the requested limit is invalid" do
      assert is_binary(Sanitizer.preview(%{value: 1}, :telemetry, max_length: -1))
    end
  end
end
