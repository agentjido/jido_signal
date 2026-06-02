defmodule Jido.Signal.Journal.Adapters.Mnesia.Tables do
  @moduledoc """
  Native Mnesia table definitions for the Mnesia journal adapter.
  """

  defmodule Signal do
    @moduledoc "Table for storing signals"
    @attributes [:id, :signal]
    defstruct @attributes

    def attributes, do: @attributes
    def type, do: :set
    def index, do: []

    def to_record(%__MODULE__{id: id, signal: signal}), do: {__MODULE__, id, signal}
    def from_record({__MODULE__, id, signal}), do: %__MODULE__{id: id, signal: signal}
  end

  defmodule Cause do
    @moduledoc "Table for cause-effect relationships (cause -> effects)"
    @attributes [:cause_id, :effects]
    defstruct @attributes

    def attributes, do: @attributes
    def type, do: :set
    def index, do: []

    def to_record(%__MODULE__{cause_id: cause_id, effects: effects}) do
      {__MODULE__, cause_id, effects}
    end

    def from_record({__MODULE__, cause_id, effects}) do
      %__MODULE__{cause_id: cause_id, effects: effects}
    end
  end

  defmodule Effect do
    @moduledoc "Table for effect-cause relationships (effect -> causes)"
    @attributes [:effect_id, :causes]
    defstruct @attributes

    def attributes, do: @attributes
    def type, do: :set
    def index, do: []

    def to_record(%__MODULE__{effect_id: effect_id, causes: causes}) do
      {__MODULE__, effect_id, causes}
    end

    def from_record({__MODULE__, effect_id, causes}) do
      %__MODULE__{effect_id: effect_id, causes: causes}
    end
  end

  defmodule Conversation do
    @moduledoc "Table for conversation signal lists"
    @attributes [:conversation_id, :signals]
    defstruct @attributes

    def attributes, do: @attributes
    def type, do: :set
    def index, do: []

    def to_record(%__MODULE__{conversation_id: conversation_id, signals: signals}) do
      {__MODULE__, conversation_id, signals}
    end

    def from_record({__MODULE__, conversation_id, signals}) do
      %__MODULE__{conversation_id: conversation_id, signals: signals}
    end
  end

  defmodule Checkpoint do
    @moduledoc "Table for subscription checkpoints"
    @attributes [:subscription_id, :checkpoint]
    defstruct @attributes

    def attributes, do: @attributes
    def type, do: :set
    def index, do: []

    def to_record(%__MODULE__{subscription_id: subscription_id, checkpoint: checkpoint}) do
      {__MODULE__, subscription_id, checkpoint}
    end

    def from_record({__MODULE__, subscription_id, checkpoint}) do
      %__MODULE__{subscription_id: subscription_id, checkpoint: checkpoint}
    end
  end

  defmodule DLQ do
    @moduledoc "Table for dead letter queue entries"
    @attributes [:id, :subscription_id, :signal, :reason, :metadata, :inserted_at]
    defstruct @attributes

    def attributes, do: @attributes
    def type, do: :set
    def index, do: [:subscription_id]

    def to_record(%__MODULE__{
          id: id,
          subscription_id: subscription_id,
          signal: signal,
          reason: reason,
          metadata: metadata,
          inserted_at: inserted_at
        }) do
      {__MODULE__, id, subscription_id, signal, reason, metadata, inserted_at}
    end

    def from_record({__MODULE__, id, subscription_id, signal, reason, metadata, inserted_at}) do
      %__MODULE__{
        id: id,
        subscription_id: subscription_id,
        signal: signal,
        reason: reason,
        metadata: metadata,
        inserted_at: inserted_at
      }
    end
  end
end
