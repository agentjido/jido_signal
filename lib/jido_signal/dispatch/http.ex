defmodule Jido.Signal.Dispatch.Http do
  @moduledoc """
  An adapter for dispatching signals via HTTP requests using Erlang's built-in :httpc client.

  This adapter implements the `Jido.Signal.Dispatch.Adapter` behaviour and provides
  functionality to send signals as HTTP requests to specified endpoints. It uses the
  built-in :httpc client to avoid external dependencies.

  ## Configuration Options

  * `:url` - (required) The URL to send the request to
  * `:method` - (optional) HTTP method to use, one of [:post, :put, :patch], defaults to :post
  * `:headers` - (optional) List of headers to include in the request
  * `:timeout` - (optional) Request timeout in milliseconds, defaults to 5000
  * `:ssl_options` - (optional) Additional TLS options. Certificate and hostname
    verification are always enforced for HTTPS requests.
  The adapter makes one request. The caller or Bus owns retry policy.

  ## Examples

      # Basic POST request
      config = {:http, [
        url: "https://api.example.com/events",
      ]}

      # Custom configuration
      config = {:http, [
        url: "https://api.example.com/events",
        method: :put,
        headers: [{"content-type", "application/json"}, {"x-api-key", "secret"}],
        timeout: 10_000
      ]}

  ## Error Handling

  The adapter handles these error conditions:

  * `:invalid_url` - The URL is not valid
  * `:connection_error` - Failed to establish connection
  * `:timeout` - Request timed out
  * Other HTTP status codes and errors
  """

  @behaviour Jido.Signal.Dispatch.Adapter

  alias Jido.Signal.Dispatch.Adapter

  @default_timeout 5000
  @default_method :post
  @max_timeout 60_000
  @valid_methods [:post, :put, :patch]
  @header_name_pattern ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  @header_value_control_pattern ~r/[\x00-\x1F\x7F]/
  @url_unsafe_pattern ~r/[\x00-\x20\x7F]/
  @protected_ssl_options [:verify, :verify_fun, :customize_hostname_check]
  @options_schema Zoi.keyword(
                    url: Zoi.string() |> Zoi.required(),
                    method: Zoi.enum(@valid_methods) |> Zoi.default(@default_method),
                    headers: Zoi.list() |> Zoi.default([]),
                    timeout: Zoi.integer() |> Zoi.min(1) |> Zoi.default(@default_timeout),
                    ssl_options: Zoi.list() |> Zoi.default([]),
                    retry: Zoi.any() |> Zoi.optional()
                  )

  @type http_method :: :post | :put | :patch
  @type header :: {String.t(), String.t()}
  @type delivery_opts :: [
          url: String.t(),
          method: http_method(),
          headers: [header()],
          timeout: pos_integer(),
          ssl_options: keyword()
        ]
  @type delivery_error ::
          :invalid_url
          | :connection_error
          | :timeout
          | {:status_error, pos_integer()}
          | term()

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Validates the HTTP adapter configuration options.

  ## Parameters

  * `opts` - Keyword list of options to validate

  ## Options

  * `:url` - Must be a valid URL string
  * `:method` - Must be one of #{inspect(@valid_methods)}
  * `:headers` - Must be a list of string tuples
  * `:timeout` - Must be a positive integer

  ## Returns

  * `{:ok, validated_opts}` - Options are valid
  * `{:error, reason}` - Options are invalid with reason
  """
  @spec validate_opts(Keyword.t()) :: {:ok, Keyword.t()} | {:error, term()}
  def validate_opts(opts) do
    with {:ok, opts} <- Adapter.validate(@options_schema, opts),
         {:ok, url} <- validate_url(Keyword.get(opts, :url)),
         {:ok, method} <- validate_method(Keyword.get(opts, :method, @default_method)),
         {:ok, headers} <- validate_headers(Keyword.get(opts, :headers, [])),
         {:ok, timeout} <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout)),
         {:ok, ssl_options} <- validate_ssl_options(Keyword.get(opts, :ssl_options, [])) do
      {:ok,
       opts
       |> Keyword.put(:url, url)
       |> Keyword.put(:method, method)
       |> Keyword.put(:headers, headers)
       |> Keyword.put(:timeout, timeout)
       |> Keyword.put(:ssl_options, ssl_options)
       |> Keyword.delete(:retry)}
    end
  end

  @impl Jido.Signal.Dispatch.Adapter
  def options_schema, do: @options_schema

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Delivers a signal via HTTP request.

  ## Parameters

  * `signal` - The signal to deliver
  * `opts` - Validated options from `validate_opts/1`

  ## Returns

  * `:ok` - Signal was delivered successfully
  * `{:error, reason}` - Delivery failed with reason

  ## Examples

      iex> signal = %Jido.Signal{type: "user:created", data: %{id: 123}}
      iex> Http.deliver(signal, [url: "https://api.example.com/events"])
      :ok
  """
  @spec deliver(Jido.Signal.t(), delivery_opts()) :: :ok | {:error, delivery_error()}
  def deliver(signal, opts) do
    with {:ok, opts} <- validate_opts(opts) do
      do_deliver(signal, opts)
    end
  end

  @doc false
  @spec do_deliver(Jido.Signal.t(), delivery_opts()) :: :ok | {:error, delivery_error()}
  def do_deliver(signal, opts) do
    url = Keyword.fetch!(opts, :url)
    method = Keyword.fetch!(opts, :method)
    headers = Keyword.fetch!(opts, :headers)
    timeout = Keyword.fetch!(opts, :timeout)
    ssl_options = Keyword.get(opts, :ssl_options, [])
    body = signal |> Jido.Signal.to_map() |> Jason.encode!()
    default_headers = [{"content-type", "application/json"}]
    headers = default_headers ++ headers

    do_request(method, url, headers, body, timeout, ssl_options)
  end

  # Private Helpers

  defp validate_url(nil), do: {:error, "url is required"}

  defp validate_url(url) when is_binary(url) do
    if Regex.match?(@url_unsafe_pattern, url) do
      {:error, "invalid url: contains whitespace or control characters"}
    else
      case URI.new(url) do
        {:ok, uri} -> validate_http_uri(uri, url)
        {:error, _part} -> {:error, "invalid url: must be a well-formed HTTP or HTTPS URL"}
      end
    end
  end

  defp validate_url(_invalid), do: {:error, "url must be a string"}

  defp validate_http_uri(%URI{userinfo: userinfo}, _url) when is_binary(userinfo) do
    {:error, "invalid url: userinfo is not allowed"}
  end

  defp validate_http_uri(%URI{scheme: scheme, host: host}, url)
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    {:ok, url}
  end

  defp validate_http_uri(_uri, _url) do
    {:error, "invalid url: must be an HTTP or HTTPS URL with a host"}
  end

  defp validate_method(method) when method in @valid_methods, do: {:ok, method}
  defp validate_method(invalid), do: {:error, "invalid method: #{inspect(invalid)}"}

  defp validate_headers(headers) when is_list(headers) do
    if Enum.all?(headers, &valid_header?/1) do
      {:ok, headers}
    else
      {:error, "invalid headers format"}
    end
  end

  defp validate_headers(invalid), do: {:error, "headers must be a list, got: #{inspect(invalid)}"}

  defp valid_header?({key, value}) when is_binary(key) and is_binary(value) do
    valid_header_name?(key) and valid_header_value?(value)
  end

  defp valid_header?(_), do: false

  @doc false
  @spec valid_header_name?(term()) :: boolean()
  def valid_header_name?(name) when is_binary(name) do
    Regex.match?(@header_name_pattern, name)
  end

  def valid_header_name?(_), do: false

  @doc false
  @spec valid_header_value?(term()) :: boolean()
  def valid_header_value?(value) when is_binary(value) do
    not Regex.match?(@header_value_control_pattern, value)
  end

  def valid_header_value?(_), do: false

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout,
       do: {:ok, timeout}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > @max_timeout,
    do: {:error, "timeout must be less than or equal to #{@max_timeout}"}

  defp validate_timeout(_), do: {:error, "timeout must be a positive integer"}

  defp validate_ssl_options(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "ssl_options must be a keyword list"}

      protected_option = protected_ssl_option(opts) ->
        {:error, "#{protected_option} cannot be overridden in ssl_options"}

      true ->
        {:ok, opts}
    end
  end

  defp validate_ssl_options(_), do: {:error, "ssl_options must be a keyword list"}

  defp protected_ssl_option(opts) do
    Enum.find(@protected_ssl_options, &Keyword.has_key?(opts, &1))
  end

  defp do_request(method, url, headers, body, timeout, ssl_options) do
    url_charlist = to_charlist(url)

    # Convert headers to charlists for :httpc
    headers_charlist = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request = {url_charlist, headers_charlist, ~c"application/json", body}
    http_options = request_options(url, timeout, ssl_options)

    case :httpc.request(method, request, http_options, []) do
      {:ok, {{_, status_code, _}, _headers, _body}}
      when status_code >= 200 and status_code < 300 ->
        :ok

      {:ok, {{_, status_code, _}, _headers, body}} ->
        {:error, {:status_error, status_code, body}}

      {:error, {:failed_connect, [{:to_address, _}, {:inet, [:inet], reason}]}}
      when reason in [:timeout, :econnrefused] ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_options(url, timeout, ssl_options) do
    base_options = [{:timeout, timeout}, {:connect_timeout, timeout}]

    case URI.parse(url) do
      %URI{scheme: "https"} ->
        [{:ssl, Keyword.merge(default_ssl_options(), ssl_options)} | base_options]

      _ ->
        base_options
    end
  end

  defp default_ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
