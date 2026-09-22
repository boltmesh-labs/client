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
* **Include your environment details** (OS, Python version, Go version, Node version, etc.)

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

* **Use a clear and descriptive title**
* **Provide a step-by-step description of the suggested enhancement**
* **Provide specific examples to demonstrate the steps**
* **Describe the current behavior and expected behavior**
* **Explain why this enhancement would be useful**

### Pull Requests

* Fill in the required template
* Follow the project's style guides (Ruff for Python, ESLint/Prettier for JavaScript, `gofmt`/`go vet` for Go)
* Include appropriate test cases
* Update documentation as needed (README.md, backend/README.md, DEPLOYMENT.md)
* End all files with a newline
* Note: the **backend is proprietary** — all backend PRs require a signed Contributor License Agreement (CLA) before they can be merged. See the License section of [README.md](README.md).

## Style Guides

### Python Style Guide

The backend follows [PEP 8](https://www.python.org/dev/peps/pep-0008/) (line length 100, Python 3.13) with Ruff and Pyright:

```bash
cd backend
uv run ruff check .
uv run ruff format .
uv run pyright .
```

Ruff enforces linting and formatting; Pyright performs static type checking. All functions and classes should have docstrings and type hints.

### JavaScript/React Style Guide

The frontend uses ESLint and Prettier:

```bash
cd frontend
npm run lint
npm run format
```

### Go Style Guide

The node agent follows standard Go conventions; use `gofmt` and run the project checks:

```bash
cd node-agent
make vet
make test
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
# Backend tests (run from backend/)
uv sync
uv run pytest

# Frontend tests
cd frontend
npm test

# Node agent tests
cd node-agent
make test

# Terraform checks
cd infra
make validate-all
```

### Writing Tests

* Write tests for all new features
* Aim for >80% code coverage (backend coverage gate is 80%)
* Use descriptive test names
* Group related tests with `pytest.mark.group_name` where appropriate

### Test Locations

Backend tests live next to the code they test:

```text
    backend/app/{module}/tests/
    ├── test_auth.py
    ├── test_users.py
    └── test_billing.py
```

Frontend tests are colocated under `frontend/src/` and run with Vitest:

```text
frontend/src/components/
├── Button.jsx
└── Button.test.jsx
```

## Documentation

* Update README.md if you change functionality
* Update backend/README.md if you change API endpoints
* Update infra/README.md if you change terraform/packer files
* Update node-agent/README.md if you change Node Agent files
* Update DEPLOYMENT.md if you change deployment procedures
* Add docstrings to all functions and classes
* Use type hints in Python code

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
