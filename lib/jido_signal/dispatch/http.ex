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
  * `:retry` - (optional) Retry configuration map with keys:
    * `:max_attempts` - Maximum number of retry attempts (default: 3)
    * `:base_delay` - Base delay between retries in milliseconds (default: 1000)
    * `:max_delay` - Maximum delay between retries in milliseconds (default: 5000)

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
        timeout: 10_000,
        retry: %{
          max_attempts: 5,
          base_delay: 2000,
          max_delay: 10000
        }
      ]}

  ## Error Handling

  The adapter handles these error conditions:

  * `:invalid_url` - The URL is not valid
  * `:connection_error` - Failed to establish connection
  * `:timeout` - Request timed out
  * `:retry_failed` - All retry attempts failed
  * Other HTTP status codes and errors
  """

  @behaviour Jido.Signal.Dispatch.Adapter

  alias Jido.Signal.Dispatch.CircuitBreaker
  alias Jido.Signal.Sanitizer
  alias Jido.Signal.Util

  @default_timeout 5000
  @default_method :post
  @default_retry %{
    max_attempts: 3,
    base_delay: 1000,
    max_delay: 5000
  }
  @max_timeout 60_000
  @max_retry_attempts 10
  @max_retry_delay 60_000
  @valid_methods [:post, :put, :patch]
  @header_name_pattern ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @type http_method :: :post | :put | :patch
  @type header :: {String.t(), String.t()}
  @type retry_config :: %{
          max_attempts: pos_integer(),
          base_delay: pos_integer(),
          max_delay: pos_integer()
        }
  @type delivery_opts :: [
          url: String.t(),
          method: http_method(),
          headers: [header()],
          timeout: pos_integer(),
          ssl_options: keyword(),
          retry: retry_config()
        ]
  @type delivery_error ::
          :invalid_url
          | :connection_error
          | :timeout
          | :retry_failed
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
  * `:retry` - Must be a valid retry configuration map

  ## Returns

  * `{:ok, validated_opts}` - Options are valid
  * `{:error, reason}` - Options are invalid with reason
  """
  @spec validate_opts(Keyword.t()) :: {:ok, Keyword.t()} | {:error, term()}
  def validate_opts(opts) do
    with {:ok, url} <- validate_url(Keyword.get(opts, :url)),
         {:ok, method} <- validate_method(Keyword.get(opts, :method, @default_method)),
         {:ok, headers} <- validate_headers(Keyword.get(opts, :headers, [])),
         {:ok, timeout} <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout)),
         {:ok, ssl_options} <- validate_ssl_options(Keyword.get(opts, :ssl_options, [])),
         {:ok, retry} <- validate_retry(Keyword.get(opts, :retry, @default_retry)) do
      {:ok,
       opts
       |> Keyword.put(:url, url)
       |> Keyword.put(:method, method)
       |> Keyword.put(:headers, headers)
       |> Keyword.put(:timeout, timeout)
       |> Keyword.put(:ssl_options, ssl_options)
       |> Keyword.put(:retry, retry)}
    end
  end

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
    CircuitBreaker.install(:http)

    CircuitBreaker.run(:http, fn ->
      do_deliver(signal, opts)
    end)
  end

  @doc false
  @spec do_deliver(Jido.Signal.t(), delivery_opts()) :: :ok | {:error, delivery_error()}
  def do_deliver(signal, opts) do
    url = Keyword.fetch!(opts, :url)
    method = Keyword.fetch!(opts, :method)
    headers = Keyword.fetch!(opts, :headers)
    timeout = Keyword.fetch!(opts, :timeout)
    ssl_options = Keyword.get(opts, :ssl_options, [])
    retry_config = Keyword.fetch!(opts, :retry)

    body = Jason.encode!(signal)
    default_headers = [{"content-type", "application/json"}]
    headers = default_headers ++ headers

    do_request_with_retry(method, url, headers, body, timeout, ssl_options, retry_config)
  end

  # Private Helpers

  defp validate_url(nil), do: {:error, "url is required"}

  defp validate_url(url) when is_binary(url) do
    if String.contains?(url, ["\r", "\n"]) do
      {:error, "invalid url: contains control characters"}
    else
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when not is_nil(scheme) and not is_nil(host) and scheme in ["http", "https"] ->
          {:ok, url}

        _ ->
          {:error,
           "invalid url: #{Sanitizer.preview(url, :telemetry)} - must be an HTTP or HTTPS URL"}
      end
    end
  end

  defp validate_url(invalid), do: {:error, "url must be a string, got: #{inspect(invalid)}"}

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
    not String.contains?(value, ["\r", "\n"])
  end

  def valid_header_value?(_), do: false

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout,
       do: {:ok, timeout}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > @max_timeout,
    do: {:error, "timeout must be less than or equal to #{@max_timeout}"}

  defp validate_timeout(_), do: {:error, "timeout must be a positive integer"}

  defp validate_ssl_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error, "ssl_options must be a keyword list"}
    end
  end

  defp validate_ssl_options(_), do: {:error, "ssl_options must be a keyword list"}

  defp validate_retry(%{} = retry) do
    with {:ok, max_attempts} <- fetch_retry_integer(retry, :max_attempts),
         {:ok, base_delay} <- fetch_retry_integer(retry, :base_delay),
         {:ok, max_delay} <- fetch_retry_integer(retry, :max_delay),
         {:ok, max_attempts} <-
           validate_positive_integer(max_attempts, :max_attempts, @max_retry_attempts),
         {:ok, base_delay} <-
           validate_positive_integer(base_delay, :base_delay, @max_retry_delay),
         {:ok, max_delay} <- validate_positive_integer(max_delay, :max_delay, @max_retry_delay),
         :ok <- validate_retry_delay_order(base_delay, max_delay) do
      {:ok,
       %{
         max_attempts: max_attempts,
         base_delay: base_delay,
         max_delay: max_delay
       }}
    end
  end

  defp validate_retry(invalid), do: {:error, "invalid retry configuration: #{inspect(invalid)}"}

  defp fetch_retry_integer(retry, field) do
    case Map.fetch(retry, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "retry configuration missing #{field}"}
    end
  end

  defp validate_positive_integer(value, _field, max)
       when is_integer(value) and value > 0 and value <= max,
       do: {:ok, value}

  defp validate_positive_integer(value, field, max) when is_integer(value) and value > max,
    do: {:error, "#{field} must be less than or equal to #{max}, got: #{inspect(value)}"}

  defp validate_positive_integer(invalid, field, _max),
    do: {:error, "#{field} must be a positive integer, got: #{inspect(invalid)}"}

  defp validate_retry_delay_order(base_delay, max_delay) when max_delay >= base_delay, do: :ok

  defp validate_retry_delay_order(_base_delay, _max_delay) do
    {:error, "max_delay must be greater than or equal to base_delay"}
  end

  defp do_request_with_retry(
         method,
         url,
         headers,
         body,
         timeout,
         ssl_options,
         retry_config,
         attempt \\ 1
       ) do
    method
    |> do_request(url, headers, body, timeout, ssl_options)
    |> handle_request_result(
      method,
      url,
      headers,
      body,
      timeout,
      ssl_options,
      retry_config,
      attempt
    )
  end

  defp handle_request_result(
         :ok,
         _method,
         _url,
         _headers,
         _body,
         _timeout,
         _ssl_options,
         _retry_config,
         _attempt
       ),
       do: :ok

  defp handle_request_result(
         {:error, reason} = error,
         method,
         url,
         headers,
         body,
         timeout,
         ssl_options,
         retry_config,
         attempt
       ) do
    if should_retry?(attempt, retry_config) do
      retry_request(
        method,
        url,
        headers,
        body,
        timeout,
        ssl_options,
        retry_config,
        attempt,
        reason
      )
    else
      log_request_failure(attempt, reason)
      error
    end
  end

  defp log_request_failure(attempt, reason) do
    Util.cond_log(Util.default_log_level(), :error, fn ->
      "HTTP dispatch failed attempts=#{attempt} reason=#{Sanitizer.preview(reason, :telemetry)}"
    end)
  end

  defp retry_request(
         method,
         url,
         headers,
         body,
         timeout,
         ssl_options,
         retry_config,
         attempt,
         reason
       ) do
    delay = calculate_delay(attempt, retry_config)

    Util.cond_log(Util.default_log_level(), :info, fn ->
      "HTTP dispatch retry attempt=#{attempt} delay_ms=#{delay} " <>
        "reason=#{Sanitizer.preview(reason, :telemetry)}"
    end)

    Process.sleep(delay)

    do_request_with_retry(
      method,
      url,
      headers,
      body,
      timeout,
      ssl_options,
      retry_config,
      attempt + 1
    )
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

  defp should_retry?(attempt, %{max_attempts: max_attempts}), do: attempt < max_attempts

  defp calculate_delay(attempt, %{base_delay: base_delay, max_delay: max_delay}) do
    delay = trunc(base_delay * :math.pow(2, attempt - 1))
    min(delay, max_delay)
  end
end
