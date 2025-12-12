import Config

# Git hooks and git_ops configuration for conventional commits
if config_env() != :prod do
  config :git_hooks,
    auto_install: true,
    verbose: true,
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "mix git_ops.check_message", include_hook_args: true}
        ]
      ]
    ]

  config :git_ops,
    mix_project: Jido.Signal.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/jido_signal",
    manage_mix_version?: true,
    manage_readme_version: "README.md",
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end
