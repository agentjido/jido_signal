defmodule Jido.Signal.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Error

  describe "to_map/1" do
    test "serializes a stable public error payload" do
      error =
        Error.dispatch_error("upstream request failed", %{
          reason: {:status_error, 503, "unavailable"},
          token: "secret-token",
          context: {:retry, %{attempt: 2}}
        })

      assert %{
               type: :dispatch_error,
               message: "upstream request failed",
               details: details,
               retryable?: true
             } = Error.to_map(error)

      assert details["token"] == "[REDACTED]"

      assert details["reason"] == %{
               "__type__" => "tuple",
               "items" => ["status_error", 503, "unavailable"]
             }

      assert details["context"] == %{
               "__type__" => "tuple",
               "items" => ["retry", %{"attempt" => 2}]
             }
    end
  end

  describe "retryable?/1" do
    test "derives timeout retryability centrally" do
      assert Error.retryable?(Error.timeout_error("timed out", %{timeout: 1000}))
      refute Error.retryable?(Error.validation_error("bad input", %{field: :type}))
    end
  end
end
