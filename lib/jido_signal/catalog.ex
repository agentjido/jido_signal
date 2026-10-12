defmodule Jido.Signal.Catalog do
  @moduledoc """
  Selects and validates explicitly registered Signal definitions.

  A catalog is an immutable value. `new/1` captures the type, `dataschema`,
  and Zoi data schema from each supplied `use Jido.Signal` module. It matches
  exact `{type, dataschema}` pairs. A definition without `dataschema` matches
  only Signals without `dataschema`. Duplicate pairs are errors, even when
  the same module appears twice. Different schema versions can share a type.

  `decode/3` uses the existing Signal codec and serialization boundary.
  `validate/2` checks an existing Signal envelope, its flat context, and its
  selected data schema. Neither function calls a constructor or generates an
  ID. The supplied ID, time, source, subject, and valid context are preserved.
  Zoi can apply data defaults and transforms declared by the definition.

  Data keys follow the definition's Zoi schema. The catalog does not enable
  coercion, convert arbitrary keys to atoms, or select modules from input.
  Use string-key schemas for JSON data. See the [catalog guide](catalog.md).

  ## Examples

      catalog = Jido.Signal.Catalog.new!([MyApp.MessageReceived, MyApp.TemperatureMeasured])
      {:ok, signal} = Jido.Signal.Catalog.decode(catalog, json)
      {:ok, signal} = Jido.Signal.Catalog.validate(catalog, signal)

  ## Errors

  All failures return `{:error, %Jido.Signal.Error.InvalidInputError{}}`.
  The `details.code` field is one of:

  * `:invalid_definitions` — registration input failed Zoi validation.
  * `:duplicate_definition` — two registrations have the same exact pair.
  * `:invalid_input` — expected a catalog, Signal, map, or binary.
  * `:invalid_options` — options were supplied for a map.
  * `:decode_failed` — the wire format or envelope is invalid, or is a batch.
  * `:invalid_envelope` — an existing Signal or its context is invalid.
  * `:unknown_type` — the type has no registered definition.
  * `:unknown_dataschema` — the type is known but the schema identity is not.
  * `:invalid_data` — the selected Zoi schema rejected the data.
  * `:validation_failed` — a trusted Zoi callback raised, threw, or exited.

  `details.reason` retains codec/serialization errors or Zoi errors where
  applicable. Lookup and data errors include `type` and `dataschema`.
  Data errors also include the selected `definition` module. Duplicate errors
  include both modules in registration order under `definitions`.

  A catalog does not migrate data, fetch schemas, authorize operations, or
  execute commands. Registered schemas and their callbacks are trusted code.
  """

  alias Jido.Signal
  alias Jido.Signal.Context
  alias Jido.Signal.Error
  alias Jido.Signal.Error.InvalidInputError
  alias Jido.Signal.Serialization

  @definitions_schema Zoi.list(Zoi.atom() |> Zoi.refine({__MODULE__, :validate_definition, []}))
  @catalog_schema Zoi.struct(__MODULE__, %{
                    definitions:
                      Zoi.map(
                        Zoi.tuple({Zoi.string(), Zoi.string() |> Zoi.nullable()}),
                        Zoi.tuple({Zoi.atom(), Zoi.any()})
                      )
                  })

  @typedoc "An immutable index of exact Signal type and schema identities."
  @type t :: unquote(Zoi.type_spec(@catalog_schema))
  @enforce_keys Zoi.Struct.enforce_keys(@catalog_schema)
  defstruct Zoi.Struct.struct_fields(@catalog_schema)

  @error_messages %{
    invalid_definitions: "Expected a list of Signal definition modules",
    duplicate_definition: "Signal definition pair is already registered",
    invalid_input: "Invalid catalog input",
    invalid_options: "Decode options apply only to binary input",
    decode_failed: "Signal wire decoding failed",
    invalid_envelope: "Invalid Signal envelope or context",
    unknown_type: "Signal type is not registered",
    unknown_dataschema: "Signal schema identity is not registered for this type",
    invalid_data: "Signal data failed definition validation",
    validation_failed: "Signal definition validation failed"
  }

  @doc """
  Builds a catalog from an explicit list of custom Signal modules.

  An empty list is valid. All duplicate `{type, dataschema}` pairs are rejected.
  The supplied modules are trusted application configuration.
  """
  @spec new([module()]) :: {:ok, t()} | {:error, %InvalidInputError{}}
  def new(modules) when is_list(modules) and is_integer(length(modules)) do
    case Zoi.parse(@definitions_schema, modules) do
      {:ok, modules} -> build(modules)
      {:error, errors} -> error(:invalid_definitions, %{reason: errors})
    end
  end

  def new(_modules),
    do: error(:invalid_definitions, %{reason: [Zoi.Error.invalid_type(:list)]})

  @doc "Builds a catalog, or raises `Jido.Signal.Error.InvalidInputError`."
  @spec new!([module()]) :: t() | no_return()
  def new!(modules) do
    case new(modules) do
      {:ok, catalog} -> catalog
      {:error, error} -> raise error
    end
  end

  @doc """
  Decodes one canonical wire map or binary and validates its definition.

  Binary options are forwarded to `Jido.Signal.Serialization.deserialize/2`.
  JSON is the default. The configured payload limit applies to binary input.
  Maps must be complete wire envelopes; constructor defaults are not added.
  Maps accept no options. Lists, JSON batches, and Signal structs are rejected.
  Use `validate/2` for an existing Signal.
  """
  @spec decode(t(), map() | binary(), keyword()) ::
          {:ok, Signal.t()} | {:error, %InvalidInputError{}}
  def decode(catalog, wire_value, opts \\ [])

  def decode(%__MODULE__{} = catalog, binary, opts) when is_binary(binary) do
    case Serialization.deserialize(binary, opts) do
      {:ok, %Signal{} = signal} ->
        validate(catalog, signal)

      {:ok, _batch} ->
        error(:decode_failed, %{reason: {:invalid_wire_data, "expected one Signal"}})

      {:error, reason} ->
        error(:decode_failed, %{reason: reason})
    end
  end

  def decode(%__MODULE__{} = catalog, map, opts) when is_map(map) and not is_struct(map) do
    if opts == [] do
      case Signal.from_map(map) do
        {:ok, signal} -> validate(catalog, signal)
        {:error, reason} -> error(:decode_failed, %{reason: reason})
      end
    else
      error(:invalid_options, %{field: :options})
    end
  end

  def decode(%__MODULE__{}, _wire_value, _opts),
    do: error(:invalid_input, %{field: :wire_value})

  def decode(_catalog, _wire_value, _opts), do: error(:invalid_input, %{field: :catalog})

  @doc """
  Revalidates an existing Signal without replacing its identity or metadata.

  The envelope and flat context are checked before exact definition lookup.
  The selected Zoi schema validates data using the same rules as construction.
  Data defaults and transforms can change the returned data value.
  """
  @spec validate(t(), Signal.t()) :: {:ok, Signal.t()} | {:error, %InvalidInputError{}}
  def validate(%__MODULE__{} = catalog, %Signal{} = signal) do
    with {:ok, signal} <- validate_envelope(signal),
         {:ok, {module, schema}} <- lookup(catalog, signal),
         {:ok, data} <- validate_data(schema, signal, module) do
      {:ok, %{signal | data: data}}
    end
  end

  def validate(%__MODULE__{}, _signal), do: error(:invalid_input, %{field: :signal})
  def validate(_catalog, _signal), do: error(:invalid_input, %{field: :catalog})

  @doc false
  @spec validate_definition(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_definition(module, _opts) do
    if Signal.defined?(module) and function_exported?(module, :dataschema, 0) and
         function_exported?(module, :schema, 0) do
      :ok
    else
      {:error, "must be a module defined with use Jido.Signal"}
    end
  end

  defp build(modules) do
    Enum.reduce_while(modules, {:ok, %__MODULE__{definitions: %{}}}, fn module, {:ok, catalog} ->
      key = {module.type(), module.dataschema()}

      case Map.fetch(catalog.definitions, key) do
        {:ok, {existing, _schema}} ->
          {type, dataschema} = key

          {:halt,
           error(:duplicate_definition, %{
             type: type,
             dataschema: dataschema,
             definitions: [existing, module]
           })}

        :error ->
          definitions = Map.put(catalog.definitions, key, {module, module.schema()})
          {:cont, {:ok, %{catalog | definitions: definitions}}}
      end
    end)
  end

  defp validate_envelope(signal) do
    with {:ok, signal} <- Zoi.parse(Signal.schema(), signal),
         {:ok, context} <- Context.normalize(signal.extensions) do
      {:ok, %{signal | extensions: context}}
    else
      {:error, reason} -> error(:invalid_envelope, %{reason: reason})
    end
  end

  defp lookup(catalog, signal) do
    case Map.fetch(catalog.definitions, {signal.type, signal.dataschema}) do
      {:ok, definition} ->
        {:ok, definition}

      :error ->
        known_type? =
          Enum.any?(catalog.definitions, fn {{type, _schema}, _value} -> type == signal.type end)

        code = if known_type?, do: :unknown_dataschema, else: :unknown_type
        error(code, identity(signal))
    end
  end

  defp validate_data(schema, signal, module) do
    case Zoi.parse(schema, signal.data) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> data_error(:invalid_data, signal, module, reason)
    end
  rescue
    exception -> data_error(:validation_failed, signal, module, {:exception, exception})
  catch
    kind, reason -> data_error(:validation_failed, signal, module, {kind, reason})
  end

  defp data_error(code, signal, module, reason) do
    error(code, Map.merge(identity(signal), %{definition: module, reason: reason}))
  end

  defp identity(signal), do: %{type: signal.type, dataschema: signal.dataschema}

  defp error(code, details) do
    {:error,
     Error.validation_error(Map.fetch!(@error_messages, code), Map.put(details, :code, code))}
  end
end
