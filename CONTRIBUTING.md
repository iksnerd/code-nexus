# Contributing to CodeNexus (Elixir Nexus)

First off, thank you for considering contributing to CodeNexus! It's people like you that make CodeNexus such a great tool.

## Code of Conduct

By participating in this project, you are expected to uphold our Code of Conduct. (Link to be added)

## How Can I Contribute?

### Reporting Bugs

This section guides you through submitting a bug report for CodeNexus. Following these guidelines helps maintainers and the community understand your report, reproduce the behavior, and find related reports.

*   **Check the existing issues** to see if the bug has already been reported.
*   **Use the bug report template** when opening a new issue.
*   **Be specific!** Include as much detail as possible: steps to reproduce, expected behavior, actual behavior, and your environment (OS, Elixir version, MCP client).

### Suggesting Enhancements

This section guides you through submitting an enhancement suggestion for CodeNexus, including completely new features and minor improvements to existing functionality.

*   **Check the existing issues** to see if the enhancement has already been suggested.
*   **Use the feature request template** when opening a new issue.
*   **Explain why** this enhancement would be useful to most CodeNexus users.

### Your First Code Contribution

Unsure where to begin contributing to CodeNexus? You can start by looking through these `beginner` and `help-wanted` issues:

*   **Beginner issues** - issues which should only require a few lines of code, and a test or two.
*   **Help-wanted issues** - issues which should be a bit more involved than `beginner` issues.

#### Local Development Setup

1.  **Fork the repository.**
2.  **Clone your fork.**
3.  **Install dependencies**: `mix deps.get`
4.  **Run Qdrant**: `docker run -d --name qdrant -p 6333:6333 qdrant/qdrant:latest`
5.  **Run tests**: `mix test`
6.  **Run the MCP server locally**: `mix mcp` (stdio) or `mix mcp_http` (HTTP/SSE).

### Pull Requests

*   **Create a new branch** for each pull request.
*   **Follow the Elixir style guide.**
*   **Include tests** for any new functionality or bug fixes.
*   **Update documentation** if your changes affect the public API or behavior.
*   **Write clear commit messages.**

## Community

You can join the discussion in our Council Hub (if applicable) or through GitHub Discussions.

## License

By contributing to CodeNexus, you agree that your contributions will be licensed under its MIT License.
