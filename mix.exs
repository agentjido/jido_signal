defmodule Jido.Signal.MixProject do
  use Mix.Project

  @version "3.0.0-beta.1"
  @source_url "https://github.com/agentjido/jido_signal"
  @description "Agent Communication Envelope, Routing, and Delivery"

  def vsn do
    @version
  end

  def project do
    [
      app: :jido_signal,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),

      # Docs
      name: "Jido Signal",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        export: "cov",
        ignore_modules: [~r/^JidoTest\./]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        ignore_warnings: "dialyzer.ignore-warnings"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.lcov": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :public_key, :ssl],
      mod: {Jido.Signal.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def docs do
    [
      main: "readme",
      api_reference: true,
      source_ref: "v#{@version}",
      source_url: @source_url,
      authors: ["Mike Hostetler <mike.hostetler@gmail.com>"],
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/signals-and-dispatch.md",
        "guides/signal-extensions.md",
        "guides/serialization.md",
        "guides/signal-router.md",
        "guides/event-bus.md",
        "guides/advanced.md",
        "guides/v2-to-v3.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ],
      groups_for_extras: [
        "Start Here": [
          "guides/getting-started.md",
          "guides/signals-and-dispatch.md"
        ],
        "Signal Format": [
          "guides/signal-extensions.md",
          "guides/serialization.md"
        ],
        "Routing and Delivery": [
          "guides/signal-router.md",
          "guides/event-bus.md"
        ],
        "Advanced Use": "guides/advanced.md",
        Upgrade: "guides/v2-to-v3.md"
      ],
      groups_for_modules: [
        "Core Signal": [
          Jido.Signal,
          Jido.Signal.Error,
          Jido.Signal.ID,
          Jido.Signal.Trace,
          Jido.Signal.Telemetry
        ],
        "Signal Routing": [
          Jido.Signal.Router,
          Jido.Signal.Router.Route
        ],
        "Event Bus": [
          Jido.Signal.Bus,
          Jido.Signal.Bus.RecordedSignal,
          Jido.Signal.Bus.Store,
          Jido.Signal.Bus.Store.Memory
        ],
        "Signal Dispatch": [
          Jido.Signal.Dispatch,
          Jido.Signal.Dispatch.Adapter,
          Jido.Signal.Dispatch.Http,
          Jido.Signal.Dispatch.LoggerAdapter,
          Jido.Signal.Dispatch.PidAdapter,
          Jido.Signal.Dispatch.PubSub
        ],
        Serialization: [
          Jido.Signal.Serialization
        ],
        "Errors & Exceptions": [
          Jido.Signal.Error.DispatchError,
          Jido.Signal.Error.Execution,
          Jido.Signal.Error.ExecutionFailureError,
          Jido.Signal.Error.Internal,
          Jido.Signal.Error.Internal.UnknownError,
          Jido.Signal.Error.InternalError,
          Jido.Signal.Error.Invalid,
          Jido.Signal.Error.InvalidInputError,
          Jido.Signal.Error.Routing,
          Jido.Signal.Error.RoutingError,
          Jido.Signal.Error.Timeout,
          Jido.Signal.Error.TimeoutError
        ]
      ]
    ]
  end

  def package do
    [
      files: [
        "lib",
        "guides",
        "mix.exs",
        "README.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "CHANGELOG.md"
      ],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Documentation" => "https://hexdocs.pm/jido_signal",
        "GitHub" => @source_url,
        "Website" => "https://jido.run",
        "Discord" => "https://jido.run/discord",
        "Changelog" => "https://github.com/agentjido/jido_signal/blob/v#{@version}/CHANGELOG.md"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Deps
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:telemetry, "~> 1.3"},
      {:splode, "~> 0.3.0"},
      {:zoi, "~> 0.18.1"},

      # Development & Test Dependencies
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:dev, :test]},
      {:castore, "~> 1.0", only: [:dev, :test]},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      # Helper to run tests with trace when needed
      # test: "test --trace --exclude flaky",
      test: "test --exclude flaky",

      # Run to check the quality of your code
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "doctor --summary",
        "docs --warnings-as-errors",
        "credo --min-priority high",
        "dialyzer"
      ]
    ]
  end
end
