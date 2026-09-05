Code.require_file("../../bench/support/suite.exs", __DIR__)

defmodule JidoSignalTest.ExtendedBenchTest do
  use ExUnit.Case, async: false
  alias JidoSignalBench.{Measure, Report, Suite}

  test "the smoke inventory includes each reviewed gap" do
    workloads = Suite.workloads("smoke")
    names = Enum.map(workloads, & &1.name)

    for name <- ~w(signal/typed signal/typed_invalid signal/invalid
                   trace/put trace/get trace/child context/put
                   serialization/base64/encode serialization/base64/decode
                   serialization/nested/encode serialization/nested/decode
                   serialization/batch/json/encode serialization/batch/json/decode
                   serialization/batch/erlang_term/encode serialization/batch/erlang_term/decode
                   serialization/invalid_json serialization/invalid_term
                   serialization/invalid_base64 serialization/oversized
                   router/wildcard_build router/wildcard_many router/deep
                   router/add router/remove router/merge
                   dispatch/dead_pid dispatch/timeout
                   bus/fanout_processes bus/concurrent_publish bus/sustained_publish
                   bus/backlog_publish bus/backlog_drain bus/large_replay
                   bus/large_replay_filtered bus/durable_reconnect
                   bus/invalid_signal bus/store_full bus/store_failure) do
      assert name in names, "missing benchmark: #{name}"
    end

    ids = Enum.map(workloads, & &1.id)
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "every added workload passes timing, result checks, and resource cleanup" do
    for workload <- Suite.extra_workloads(2) do
      assert length(Measure.timing(workload, 1, 1).wall_ns.samples) == 1
      resources = Measure.resources(workload)
      assert resources.owned_remaining == 0

      if workload.name == "bus/fanout_processes" do
        assert workload.dimensions.consumers == 2
        assert resources.owned_process_starts >= 4
      end

      if workload.name == "bus/backlog_publish" do
        assert resources.observed_peak.mailbox_messages >= workload.dimensions.records
      end
    end
  end

  test "raw binary fixtures force Base64 and batch dimensions increase with size" do
    workloads = Suite.extra_workloads(2)
    binary = Enum.find(workloads, &(&1.name == "serialization/base64/encode"))
    refute String.valid?(binary.retained.data)
    assert Map.has_key?(Jido.Signal.to_map(binary.retained), "data_base64")

    for size <- [2, 8, 32] do
      cases = Suite.extra_workloads(size)
      batch = Enum.find(cases, &(&1.name == "serialization/batch/json/encode"))
      assert batch.dimensions.records == size
      wildcard = Enum.find(cases, &(&1.name == "router/wildcard_many"))
      assert wildcard.dimensions.wildcard_routes == size * 16
      paths = JidoSignalBench.RouterCases.wildcard_specs(size * 16) |> Enum.map(&elem(&1, 0))
      assert length(Enum.uniq(paths)) == size * 16
      replay = Enum.find(cases, &(&1.name == "bus/large_replay"))
      assert replay.dimensions.records == size * 256
    end
  end

  test "growth checks use fixture heap limits" do
    checks = Suite.check_growth!()
    assert length(checks) == 2
    assert Enum.all?(checks, &(&1.ratio <= &1.limit))
    assert_raise ArgumentError, fn -> Suite.extra_workloads(1) end
  end

  test "optional comparison budgets reject a slower or larger candidate" do
    before = report(100, 1_000)
    candidate = report(150, 1_400)
    assert :ok == Report.check_budgets!(before, candidate, [])

    assert :ok ==
             Report.check_budgets!(before, candidate, max_time_ratio: 1.6, max_memory_ratio: 1.5)

    assert_raise ArgumentError, ~r/time.*case/, fn ->
      Report.check_budgets!(before, candidate, max_time_ratio: 1.2)
    end

    assert_raise ArgumentError, ~r/memory.*case/, fn ->
      Report.check_budgets!(before, candidate, max_memory_ratio: 1.2)
    end

    assert_raise ArgumentError, ~r/positive/, fn ->
      Report.check_budgets!(before, candidate, max_time_ratio: 0)
    end

    assert_raise ArgumentError, ~r/environment/, fn ->
      Report.check_budgets!(before, %{candidate | "environment" => %{"otp" => "different"}}, [])
    end

    assert_raise ArgumentError, ~r/zero baseline/, fn ->
      Report.check_budgets!(report(0, 1_000), candidate, max_time_ratio: 1.2)
    end
  end

  defp report(time, memory) do
    %{
      "schema_version" => 2,
      "suite" => "jido_signal",
      "environment" => %{},
      "settings" => %{},
      "method" => "test",
      "source" => %{"tool_sha256" => "same"},
      "cases" => [
        %{
          "id" => "case",
          "timing" => %{"wall_ns" => %{"median" => time}, "caller_reductions" => %{"median" => 1}},
          "resources" => %{
            "observed_peak" => %{"process_memory_bytes" => memory},
            "owned_remaining" => 0
          },
          "retained_term" => %{"flat_heap_bytes" => 100}
        }
      ]
    }
  end
end
