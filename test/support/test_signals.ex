defmodule JidoTest.TestSignals do
  @moduledoc false

  defmodule DocExampleSignal do
    @moduledoc false

    use Jido.Signal,
      type: "doc.example",
      schema: [
        user_id: [type: :string, required: true],
        message: [type: :string, required: true]
      ]
  end
end
