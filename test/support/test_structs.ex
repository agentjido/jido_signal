defmodule JidoTest.TestStructs do
  @moduledoc false

  defmodule TestStruct do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:field1, :field2]
  end

  defmodule CustomDecodedStruct do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:value]
  end

  # Custom decoder implementation
  defimpl Jido.Signal.Serialization.JsonDecoder, for: CustomDecodedStruct do
    def decode(%CustomDecodedStruct{value: nil} = data), do: data

    def decode(%CustomDecodedStruct{value: value}) when is_number(value) do
      %CustomDecodedStruct{value: value * 2}
    end

    def decode(%CustomDecodedStruct{} = data), do: data
  end
end
