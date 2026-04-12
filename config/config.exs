import Config

config :jido_signal,
  default_log_level: :info,
  normalize_dispatch_errors: true

# Git hooks and git_ops configuration for conventional commits
# Only configure when the dependencies are actually available (dev environment)
if config_env() == :dev do
  # git_hooks walks upward looking for a .git directory, which fails in linked worktrees
  # where .git is a file. Point it at the project root explicitly so auto-install still works.
  config :git_hooks,
    auto_install: true,
    project_path: Path.expand("..", __DIR__),
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
