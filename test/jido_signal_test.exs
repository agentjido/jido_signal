defmodule Jido.SignalTest do
  use ExUnit.Case

  alias Jido.Signal

  defmodule ExampleStruct do
    defstruct [:value]
  end

  test "map_to_signal_data sets a generated string id and default time" do
    signal = Signal.map_to_signal_data(%ExampleStruct{value: 42})

    assert is_binary(signal.id)
    assert is_binary(signal.time)
    assert signal.data == %ExampleStruct{value: 42}
  end
end
