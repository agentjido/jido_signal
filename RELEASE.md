# Release Runbook

This runbook is for Jido Signal v3 beta releases. It follows the Jido Action v3
release pattern.

## Release names

- Use the `release/v3` branch.
- Use a version such as `3.0.0-beta.1` in `mix.exs`.
- Use a signed, annotated tag such as `v3.0.0-beta.1`.
- Use `Release v3.0.0-beta.1` as the tag message.
- Do not move or reuse a release tag.

## Prepare the branch

1. Start from the current remote release branch.

   ```sh
   git switch release/v3
   git pull --ff-only origin release/v3
   ```

2. Set the package version and all version-specific documentation.
3. Keep the Elixir requirement at `~> 1.18`.
4. Use Conventional Commit messages. Use this subject for the main release
   preparation commit:

   ```text
   feat!: prepare jido_signal 3.0.0-beta.1
   ```

5. Use this subject for a separate release workflow change when one is
   necessary:

   ```text
   ci: require manual release publication
   ```

## Run the release gates

Run these commands with Elixir 1.18 and OTP 27:

```sh
mix deps.get
mix deps.unlock --check-unused
mix hex.audit
mix quality
MIX_ENV=test mix test --cover --warnings-as-errors
mix test --include flaky --warnings-as-errors
```

Run `mix quality` and the coverage command again with the latest supported
Elixir and OTP versions. The release workflow defines these latest versions.

Push `release/v3`, and wait for the branch CI workflow to pass.

## Inspect the Hex package

Use a new shell for `mix hex.build`. The task must run before another Mix task
loads the application.

```sh
package_dir="$(mktemp -d)/jido_signal-3.0.0-beta.1"
mix hex.build --unpack --output "$package_dir"
find "$package_dir" -type f | sort
mix hex.publish --dry-run --yes
```

Confirm that the package has the expected version, source files, guides,
license, readme, contribution guide, changelog, and usage rules. A dry run must
not upload a package or documentation.

## Create the release tag

Do this section only after all local and remote checks pass.

1. Confirm that `release/v3` is clean and matches its remote branch.
2. Confirm that the version is not on Hex and that the tag does not exist.
3. Create and verify the signed tag.

   ```sh
   git tag -s -a v3.0.0-beta.1 -m "Release v3.0.0-beta.1"
   git tag --verify v3.0.0-beta.1
   git push origin v3.0.0-beta.1
   ```

Pushing the tag does not publish the release. The release workflow is manual.

## Publish the formal release

Run the `Release` workflow for the existing tag. The normal workflow input is:

```text
tag_name: v3.0.0-beta.1
dry_run: false
hex_dry_run: false
```

The workflow runs the quality, coverage, and Hex audit gates before it publishes
to Hex or creates a GitHub release. After it passes, confirm the package version
on Hex, the documentation on HexDocs, and the GitHub release.

If publication fails after a tag is public, do not move the tag. Fix the cause
on `release/v3`, and use the next beta version and tag.
