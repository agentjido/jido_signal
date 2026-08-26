defmodule Jido.Signal.SanitizerTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Sanitizer

  defmodule DetailError do
    defexception [:message, :code]
  end

  defmodule ScalarStruct do
    defstruct [:id, :status, :payload]
  end

  defmodule NestedStruct do
    defstruct payload: %{}
  end

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

    test "uses boundary-safe scalar and binary values" do
      assert Sanitizer.sanitize(:accepted, :telemetry) == :accepted
      assert Sanitizer.sanitize(:accepted, :transport) == "accepted"
      assert Sanitizer.sanitize(nil, :transport) == nil
      assert Sanitizer.sanitize(12.5, :telemetry) == 12.5

      invalid_binary = <<255, 0, 1>>

      assert %{__type__: :binary, bytes: 3, preview: preview} =
               Sanitizer.sanitize(invalid_binary, :telemetry)

      assert is_binary(preview)

      assert %{"__type__" => "binary", "bytes" => 3} =
               Sanitizer.sanitize(invalid_binary, :transport)
    end

    test "formats date and time values" do
      assert Sanitizer.sanitize(~D[2026-08-26], :transport) == "2026-08-26"
      assert Sanitizer.sanitize(~T[12:30:01], :telemetry) == "12:30:01"

      assert Sanitizer.sanitize(~N[2026-08-26 12:30:01], :transport) ==
               "2026-08-26T12:30:01"

      assert Sanitizer.sanitize(~U[2026-08-26 12:30:01Z], :telemetry) ==
               "2026-08-26T12:30:01Z"
    end

    test "keeps only safe Signal fields in telemetry" do
      signal =
        Signal.new!("user.created", %{password: "hidden"},
          source: "/users",
          subject: "user-1"
        )

      assert %{type: "user.created", source: "/users", subject: "user-1"} =
               Sanitizer.sanitize(signal, :telemetry)

      refute Map.has_key?(Sanitizer.sanitize(signal, :telemetry), :data)
    end

    test "sanitizes exception fields and general structs" do
      assert %{module: module, details: %{code: 42}} =
               Sanitizer.sanitize(DetailError.exception(message: "secret", code: 42), :telemetry)

      assert module =~ "DetailError"

      assert %{"__struct__" => struct_module, "id" => "one", "status" => "ready"} =
               Sanitizer.sanitize(
                 %ScalarStruct{id: "one", status: :ready, payload: %{secret: "hidden"}},
                 :transport
               )

      assert struct_module =~ "ScalarStruct"

      assert %{__struct__: nested_module, summary: %{summary: :list, count: 1}} =
               Sanitizer.sanitize(%NestedStruct{}, :telemetry)

      assert nested_module =~ "NestedStruct"
    end

    test "bounds maps and lists with profile-specific markers" do
      telemetry_map = Map.new(1..12, &{"key-#{&1}", &1})
      sanitized_map = Sanitizer.sanitize(telemetry_map, :telemetry)
      assert sanitized_map.__truncated__ == %{count: 12}

      transport_map = Map.new(1..52, &{"key-#{&1}", &1})

      assert %{"__truncated__" => %{"count" => 52}} =
               Sanitizer.sanitize(transport_map, :transport)

      telemetry_list = Sanitizer.sanitize(Enum.to_list(1..12), :telemetry)
      assert List.last(telemetry_list) == "... (2 more)"

      transport_list = Sanitizer.sanitize(Enum.to_list(1..52), :transport)
      assert List.last(transport_list) == %{"__truncated__" => %{"count" => 52}}
    end

    test "summarizes deep maps and lists" do
      nested_map = %{one: %{two: %{three: %{four: :value}}}}

      assert %{one: %{two: %{three: %{summary: :map, size: 1}}}} =
               Sanitizer.sanitize(nested_map, :telemetry)

      nested_list = [[[[[[[:value]]]]]]]

      assert [[[[[[%{"summary" => "list", "count" => 1}]]]]]] =
               Sanitizer.sanitize(nested_list, :transport)
    end

    test "normalizes map keys and opaque runtime values" do
      reference = make_ref()
      function = fn -> :ok end
      bitstring = <<1::1>>

      sanitized =
        Sanitizer.sanitize(
          %{{:tuple, :key} => reference, "x-token" => "hidden", function: function},
          :transport
        )

      assert sanitized["x-token"] == "[REDACTED]"
      assert sanitized["{:tuple, :key}"]["__type__"] == "reference"
      assert sanitized["function"]["__type__"] == "function"
      assert Sanitizer.sanitize(bitstring, :transport)["__type__"] == "bitstring"
      assert is_binary(Sanitizer.sanitize(self(), :telemetry))
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

    test "supports the transport default and a zero limit" do
      assert is_binary(Sanitizer.preview(%{value: 1}, :transport))
      assert Sanitizer.preview(%{value: 1}, :telemetry, max_length: 0) == "..."
    end
  end
end
