defmodule Jido.Signal.IDTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.ID

  describe "generation" do
    test "generates a valid UUID7 with its timestamp" do
      before_ms = System.system_time(:millisecond)
      {uuid, timestamp} = ID.generate()
      after_ms = System.system_time(:millisecond)

      assert ID.valid?(uuid)
      assert timestamp in before_ms..after_ms
      assert ID.extract_timestamp(uuid) == timestamp
      assert <<_timestamp::48, 7::4, _random_a::12, 2::2, _random_b::62>> = decode(uuid)
    end

    test "generate!/0 returns only the UUID7" do
      assert ID.generate!() |> ID.valid?()
    end

    test "generates unique IDs" do
      ids = Enum.map(1..1_000, fn _number -> ID.generate!() end)
      assert length(Enum.uniq(ids)) == 1_000
    end
  end

  describe "valid?/1" do
    test "accepts RFC 9562 and mixed-case UUID7 values" do
      uuid = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"

      assert ID.valid?(uuid)
      assert ID.valid?(String.upcase(uuid))
    end

    test "rejects invalid shape, version, and variant values" do
      refute ID.valid?("not-a-uuid")
      refute ID.valid?("017f22e279b07cc398c4dc0c0c07398f")
      refute ID.valid?("017f22e2-79b0-6cc3-98c4-dc0c0c07398f")
      refute ID.valid?("017f22e2-79b0-7cc3-78c4-dc0c0c07398f")
      refute ID.valid?(123)
      refute ID.valid?(nil)
    end
  end

  describe "reading and comparison" do
    test "extracts the timestamp" do
      uuid = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
      assert ID.extract_timestamp(uuid) == 1_645_557_742_000
    end

    test "compares complete UUID values" do
      older = "017f22e2-79b0-7000-8000-000000000000"
      newer = "017f22e2-79b1-7000-8000-000000000000"

      assert ID.compare(older, newer) == :lt
      assert ID.compare(newer, older) == :gt
      assert ID.compare(older, older) == :eq
    end

    test "treats mixed-case forms of one UUID as equal" do
      uuid = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
      assert ID.compare(uuid, String.upcase(uuid)) == :eq
    end

    test "raises a clear error for invalid input" do
      assert_raise ArgumentError, "expected a valid UUID7 string", fn ->
        ID.extract_timestamp("not-a-uuid")
      end
    end
  end

  defp decode(uuid) do
    {:ok, raw} = uuid |> String.replace("-", "") |> Base.decode16(case: :mixed)
    raw
  end
end
