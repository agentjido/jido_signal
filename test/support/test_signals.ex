defmodule JidoTest.TestSignals do
  @moduledoc false

  defmodule DocExampleSignal do
    @moduledoc false

    use Jido.Signal,
      type: "doc.example",
      schema: Zoi.object(%{user_id: Zoi.string(), message: Zoi.string()})
  end
end
