# Contributing to BoltMesh

First off, thank you for considering contributing to BoltMesh! It's people like you that make BoltMesh such a great tool.

## Code of Conduct

This project and everyone participating in it is governed by our Code of Conduct. By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

> **Found a security vulnerability?** Please do **not** open a bug report, issue, or PR for it — follow [SECURITY.md](SECURITY.md) to submit a private vulnerability advisory instead.

Before creating bug reports, please check the issue list as you might find out that you don't need to create one. When you are creating a bug report, please include as many details as possible:

* **Use a clear and descriptive title**
* **Describe the exact steps which reproduce the problem**
* **Provide specific examples to demonstrate the steps**
* **Describe the behavior you observed after following the steps**
* **Explain which behavior you expected to see instead and why**
* **Include screenshots/logs if possible**
* **Include your environment details** (OS, Flutter version, Go version, etc.)

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

* **Use a clear and descriptive title**
* **Provide a step-by-step description of the suggested enhancement**
* **Provide specific examples to demonstrate the steps**
* **Describe the current behavior and expected behavior**
* **Explain why this enhancement would be useful**

### Pull Requests

* Fill in the required template
* Follow the project's style guides (Dart/Flutter for `lib/`, `gofmt`/`go vet` for the Go `boltmeshd` helper)
* Include appropriate test cases
* Update documentation as needed (README.md, DEPLOYMENT.md)
* End all files with a newline

## Style Guides

### Dart/Flutter Style Guide

The client follows the lints in `analysis_options.yaml` (a strict
`flutter_lints` set: `strict-casts`, `strict-raw-types`, `strict-inference`,
plus `unawaited_futures`, `prefer_relative_imports`, `directives_ordering`,
`avoid_print`, `prefer_single_quotes`, …):

```bash
dart format lib test
flutter analyze --fatal-infos
```

`dart format` is the formatter; `flutter analyze` is the linter and type
checker. Both run in CI and via pre-commit.

### Go Style Guide

The privileged Linux helper (`linux/boltmeshd/`) follows standard Go
conventions; use `gofmt` and run the project checks:

```bash
make -C linux/boltmeshd vet
make -C linux/boltmeshd test
```

### Git Commit Messages

* Use the present tense ("Add feature" not "Added feature")
* Use the imperative mood ("Move cursor to..." not "Moves cursor to...")
* Limit the first line to 72 characters or less
* Reference issues and pull requests liberally after the first line

Example:

```text
Add peer cleanup on subscription expiry

- Deactivate WireGuard peers for expired subscriptions
- Reconcile active peer counts on VPN servers

Fixes #123
```

## Testing

### Running Tests

```bash
flutter test
# Coverage (report-only unless the 80% floor is passed):
flutter test --coverage && bash tool/coverage_gate.sh 80

# Everything CI enforces:
flutter analyze --fatal-infos
dart format --set-exit-if-changed lib test
bash tool/check_generated.sh
```

### Writing Tests

* Write tests for all new features
* Aim for >80% code coverage (enforced on hand-written lines by `tool/coverage_gate.sh`)
* Use descriptive test names
* Keep tests deterministic: drive timers with `package:fake_async` (`async.elapse`), never real sleeps

### Test Locations

`test/` mirrors `lib/` (`core/`, `features/auth/{data,state}/`,
`features/vpn/{data,domain,state}/`). App-level suites (`widget_test.dart`,
`regions_refresh_test.dart`) stay at the `test/` root, and shared doubles live
in `test/support/fakes.dart` (state suites layer fixtures on
`test/support/vpn_harness.dart`).

## Documentation

* Update README.md if you change functionality
* Update DEPLOYMENT.md if you change deployment procedures
* Add doc comments to public APIs

## Issue and Pull Request Labels

This section lists the labels we use to help track and manage issues and pull requests.

* `bug` - Something isn't working
* `enhancement` - New feature or request
* `documentation` - Improvements or additions to documentation
* `good first issue` - Good for newcomers
* `help wanted` - Extra attention is needed
* `question` - Further information is requested
* `security` - Security-related issue
* `performance` - Performance improvement

## Additional Notes

### Issue and Pull Request Process

1. After you submit your pull request, verify that all status checks are passing
2. If a status check is failing, and you believe that the failure is unrelated to your change, please leave a comment on the pull request explaining why you believe the failure is unrelated
3. A project maintainer will review your code and may request changes or improvements
4. Once approved, your code will be merged into the main branch

### Community

* Use discussions for feature ideas
* Join our Discord community (link TBD)
* Follow us on Twitter for updates

## Questions?

Feel free to contact the maintainers:

* 📧 Email: `9992383+regularnmae@users.noreply.github.com`
* 💬 GitHub Discussions: [Link]

Thank you for contributing! 🎉
