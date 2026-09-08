defmodule Jido.Signal.Router.DSL do
  @moduledoc false

  alias Jido.Signal.Router

  @doc """
  Declares one route.

  Accepts the same path and target specifications as `Jido.Signal.Router.new/1`.
  The path may be a string or a `use Jido.Signal` module. Match predicates
  must be `{module, function, args}` MFA values.
  """
  @spec route(term(), term()) :: Macro.t()
  defmacro route(path, target) do
    store_route(path, [target], __CALLER__)
  end

  @doc "Declares one route with a match predicate or priority."
  @spec route(term(), term(), term()) :: Macro.t()
  defmacro route(path, match_or_target, target_or_priority) do
    store_route(path, [match_or_target, target_or_priority], __CALLER__)
  end

  @doc "Declares one route with a match predicate and priority."
  @spec route(term(), term(), term(), term()) :: Macro.t()
  defmacro route(path, match, target, priority) do
    store_route(path, [match, target, priority], __CALLER__)
  end

  @doc "Compiles accumulated `route` declarations into Router accessors."
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    specs =
      env.module
      |> Module.get_attribute(:__jido_signal_routes__)
      |> List.wrap()
      |> Enum.reverse()

    ensure_path_modules_compiled(specs)
    validate_compiled_matches!(specs, env)

    case Router.new(specs) do
      {:ok, router} ->
        {:ok, routes} = Router.list(router)

        quote do
          @doc "Returns the compiled Router value."
          @spec router() :: Jido.Signal.Router.t()
          def router, do: unquote(Macro.escape(router))

          @doc "Returns Routes in declaration order."
          @spec routes() :: [Jido.Signal.Router.Route.t()]
          def routes, do: unquote(Macro.escape(routes))

          @doc "Returns targets for a Signal from this Router."
          @spec route(Jido.Signal.t()) :: {:ok, [term()]} | {:error, term()}
          def route(signal), do: Jido.Signal.Router.route(router(), signal)
        end

      {:error, error} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: Exception.message(error)
    end
  end

  defp store_route(path, [target], caller) do
    quote line: caller.line do
      @__jido_signal_routes__ {unquote(path), unquote(target)}
    end
  end

  defp store_route(path, [match_or_target, target_or_priority], caller) do
    quote line: caller.line do
      @__jido_signal_routes__ {unquote(path), unquote(match_or_target),
                               unquote(target_or_priority)}
    end
  end

  defp store_route(path, [match, target, priority], caller) do
    quote line: caller.line do
      @__jido_signal_routes__ {unquote(path), unquote(match), unquote(target), unquote(priority)}
    end
  end

  defp ensure_path_modules_compiled(specs) do
    Enum.each(specs, fn spec ->
      case route_path(spec) do
        module when is_atom(module) -> Code.ensure_compiled(module)
        _path -> :ok
      end
    end)
  end

  defp route_path(spec) when is_tuple(spec) and tuple_size(spec) >= 2, do: elem(spec, 0)
  defp route_path(_spec), do: nil

  defp validate_compiled_matches!(specs, env) do
    Enum.each(specs, fn
      {_path, _target, priority} when is_integer(priority) ->
        :ok

      {_path, match, _target} ->
        validate_mfa!(match, env)

      {_path, match, _target, _priority} ->
        validate_mfa!(match, env)

      _spec ->
        :ok
    end)
  end

  defp validate_mfa!({module, function, args}, _env)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: :ok

  defp validate_mfa!(_match, env) do
    compile_error!(env, "route match must be a {Module, :function, args} MFA")
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end
