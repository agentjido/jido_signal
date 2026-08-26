defmodule Jido.Signal.Dispatch.HttpTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Dispatch.Http

  test "validates and defaults HTTP options" do
    assert {:ok, opts} = Http.validate_opts(url: "https://example.com/events")
    assert opts[:url] == "https://example.com/events"
    assert opts[:method] == :post
    assert opts[:headers] == []
    assert opts[:timeout] == 5_000
    assert opts[:ssl_options] == []
    refute Keyword.has_key?(opts, :retry)
  end

  test "rejects unsafe URLs and headers" do
    assert {:error, _reason} = Http.validate_opts(url: "https://user:pass@example.com")
    assert {:error, _reason} = Http.validate_opts(url: "https://example.com/a b")

    assert {:error, _reason} =
             Http.validate_opts(url: "https://example.com", headers: [{"x-test", "bad\nvalue"}])
  end

  test "does not permit TLS verification overrides" do
    assert {:error, _reason} =
             Http.validate_opts(url: "https://example.com", ssl_options: [verify: :verify_none])
  end

  test "ignores the removed retry option" do
    assert {:ok, opts} =
             Http.validate_opts(
               url: "https://example.com",
               retry: %{max_attempts: 10, base_delay: 1, max_delay: 10}
             )

    refute Keyword.has_key?(opts, :retry)
  end
end
