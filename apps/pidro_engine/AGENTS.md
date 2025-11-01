# agents.md

## IMPORTANT

- **NEVER modify game specs/rules** - they live in separate documentation
- **NEVER delete test files** or fixture data
- This file defines HOW to build and validate, not WHAT to build
- All code must pass validation before claiming completion

## Quick Validation Loop

```bash
# Fast feedback (< 10 seconds)
mix test --stale && mix format --check-formatted

# Full validation before committing
mix quality && mix test

# The golden rule: if this passes, you're good
mix test && mix dialyzer && echo "✅ READY TO COMMIT"
```

## Core Development Commands

### Testing & Validation

```bash
# Primary workflow
mix test                                    # All tests must pass
mix test --failed                           # Re-run only failed tests
mix test --stale                            # Only changed tests
mix test test/path/to/test.exs             # Test specific file
mix test test/path/to/test.exs:42          # Test specific line

# Coverage tracking
mix coveralls                               # Generate coverage report
mix coveralls.html                          # HTML report → cover/excoveralls.html
# Coverage must not decrease with new code

# Type checking (catches bugs before runtime)
mix dialyzer                                # First run slow, then fast
mix dialyzer --format dialyxir             # Pretty output

# Code quality
mix credo --strict                          # Linting
mix format                                  # Auto-format code
mix format --check-formatted                # Check without changing
mix quality                                 # Runs: format + dialyzer + credo
```

### Fast Development Workflow

```bash
# Strict compilation
mix compile --warnings-as-errors

# Interactive development
iex -S mix                                  # Start with project loaded
recompile()                                 # In iex: recompile after changes

# Continuous feedback
mix test.watch                              # Auto-run tests (if installed)
```

## Code Style & Elixir Idioms

### Pattern Matching Over Conditionals

```elixir
# ✅ GOOD: Pattern match in function heads
def process(%State{status: :ready} = state, data) when is_binary(data) do
  {:ok, do_process(state, data)}
end

def process(%State{status: status}, _data) do
  {:error, "Cannot process in #{status} state"}
end

# ❌ BAD: Using if/case unnecessarily
def process(state, data) do
  if state.status == :ready do
    if is_binary(data) do
      {:ok, do_process(state, data)}
    end
  end
end
```

### Tagged Tuples for Return Values

```elixir
# ✅ GOOD: Always use tagged tuples for public APIs
{:ok, result}                               # Success
{:error, reason}                            # Clear error
{:error, :invalid_input, "Details"}        # Detailed error

# For private functions that can't fail
defp transform(data), do: String.upcase(data)

# ❌ BAD: Raising for domain logic (only for programmer errors)
def risky() do
  raise "Something went wrong"  # Don't do this!
end
```

### with for Complex Operations

```elixir
# ✅ GOOD: Chain validations cleanly
def complex_operation(input) do
  with {:ok, validated} <- validate(input),
       {:ok, processed} <- process(validated),
       {:ok, result} <- finalize(processed) do
    {:ok, result}
  end
end

# ❌ BAD: Nested case statements
def complex_operation(input) do
  case validate(input) do
    {:ok, validated} ->
      case process(validated) do
        {:ok, processed} ->
          finalize(processed)
      end
  end
end
```

### Module Organization

```elixir
defmodule MyApp.Feature do
  @moduledoc """
  One-line description of module purpose.

  Longer explanation with usage examples and context.
  """

  # Public API at top
  @doc """
  Brief description.

  ## Parameters
  - `param` - Description

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> MyApp.Feature.do_thing("input")
      {:ok, "output"}
  """
  @spec do_thing(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def do_thing(param) do
    # Implementation
  end

  # Private functions at bottom
  defp helper(data), do: transform(data)
end
```

## Documentation Requirements

**Every public function MUST have:**

```elixir
@doc """
Brief description of function purpose.

## Parameters
- `param_name` - What it represents

## Returns
- Success case
- Error cases

## Examples

    iex> ModuleName.function_name(arg)
    expected_result
"""
@spec function_name(type()) :: return_type()
def function_name(param) do
  # implementation
end
```

**Every module MUST have:**

- `@moduledoc` explaining purpose
- `@type` definitions for custom types
- `@spec` for all public functions

## Testing Strategy

### Write Tests First (TDD)

```elixir
# 1. Write failing test (RED)
test "descriptive test name" do
  assert MyModule.function(input) == expected
end

# 2. Implement to make it pass (GREEN)
# 3. Refactor if needed
# 4. Ensure all tests still pass
```

### Test Structure

```elixir
defmodule MyApp.FeatureTest do
  use ExUnit.Case, async: true

  alias MyApp.Feature

  describe "function_name/1" do
    test "handles valid input" do
      assert {:ok, result} = Feature.function_name("valid")
      assert result == expected
    end

    test "rejects invalid input" do
      assert {:error, _reason} = Feature.function_name("invalid")
    end
  end

  describe "edge_cases" do
    setup do
      # Common setup for this group
      {:ok, state: initial_state()}
    end

    test "handles edge case", %{state: state} do
      # Test using setup data
    end
  end
end
```

### Test Categories

```elixir
# Unit tests: Fast, many, isolated
test "pure function logic"

# Integration tests: Slower, fewer, realistic
@tag :integration
test "full workflow from start to finish"

# Property tests: Invariants that should always hold
@tag :property
property "invariant always holds" do
  check all input <- generator() do
    assert invariant(process(input))
  end
end
```

## LLM Validation Protocol

### Before Starting Work

```bash
# 1. Ensure clean baseline
mix test                                    # Must pass
mix dialyzer                                # Must pass
git status                                  # Check working directory

# 2. Understand the task
# - Read TODO/issue description
# - Check related documentation
# - Review existing tests for context
```

### While Implementing

```bash
# Follow TDD cycle
mix test test/path/to_new_test.exs         # Watch it fail (RED)
# Implement feature
mix test test/path/to_new_test.exs         # Watch it pass (GREEN)
mix format                                  # Format
```

### After Implementing

```bash
# Required validation sequence (in order)
mix format                                  # Auto-format
mix compile --warnings-as-errors            # No warnings
mix test                                    # All tests pass
mix dialyzer                                # Type check
mix credo --strict                          # Linting

# If ALL pass:
git add .
git commit -m "type: description"

# If ANY fail: FIX before proceeding
```

### Self-Validation Checklist

Before claiming work is complete:

- [ ] `mix test` passes
- [ ] `mix dialyzer` passes
- [ ] `mix credo --strict` passes
- [ ] `mix format --check-formatted` passes
- [ ] Coverage didn't decrease
- [ ] All public functions have `@spec` and `@doc`
- [ ] Tests cover success AND error cases
- [ ] Returns use tagged tuples `{:ok, _}` or `{:error, _}`
- [ ] No compiler warnings
- [ ] Documentation matches implementation

## Common Mistakes to Avoid

### ❌ Forgetting to Handle All Cases

```elixir
# BAD: Missing pattern match
def process(%State{ready: true} = state) do
  {:ok, do_work(state)}
end
# What if ready: false? Crash!

# GOOD: Explicit handling
def process(%State{ready: true} = state) do
  {:ok, do_work(state)}
end

def process(%State{ready: false}) do
  {:error, "State not ready"}
end
```

### ❌ Attempting Mutation

```elixir
# BAD: Elixir data is immutable
def update(state) do
  state.counter = state.counter + 1  # Won't work!
  state
end

# GOOD: Return new structure
def update(state) do
  %{state | counter: state.counter + 1}
end
```

### ❌ Missing Type Specs

```elixir
# BAD: No type information
def process(data) do
  # implementation
end

# GOOD: Clear types
@spec process(String.t()) :: {:ok, integer()} | {:error, atom()}
def process(data) do
  # implementation
end
```

### ❌ Not Using with for Error Handling

```elixir
# BAD: Nested pattern matching
case step1(input) do
  {:ok, result1} ->
    case step2(result1) do
      {:ok, result2} ->
        step3(result2)
      error -> error
    end
  error -> error
end

# GOOD: Clean with statement
with {:ok, result1} <- step1(input),
     {:ok, result2} <- step2(result1),
     {:ok, result3} <- step3(result2) do
  {:ok, result3}
end
```

## Type Specifications

### Define Custom Types

```elixir
@type result :: {:ok, term()} | {:error, atom()}
@type status :: :pending | :processing | :complete | :failed
@type id :: String.t()

# Use in specs
@spec process(id(), map()) :: result()
def process(id, data) do
  # implementation
end
```

### Common Type Patterns

```elixir
# Basic types
@type string_result :: {:ok, String.t()} | {:error, atom()}
@type list_of_ids :: [String.t()]
@type optional_value :: term() | nil

# Struct types
@type t :: %__MODULE__{
  field1: String.t(),
  field2: integer(),
  field3: atom()
}

# Union types
@type response :: success_response() | error_response()
@type success_response :: {:ok, result :: term()}
@type error_response :: {:error, reason :: atom() | String.t()}
```

## Debugging Techniques

### In IEx

```elixir
# Start with project loaded
iex -S mix

# Inspect values
some_value |> IO.inspect(label: "Debug")

# Recompile after changes
recompile()

# Get function documentation
h MyModule.function_name

# See function specs
s MyModule.function_name

# View source
open MyModule
```

### Test Debugging

```bash
# Run with detailed output
mix test --trace

# Run single test
mix test test/path/to/test.exs:42

# See full error details
mix test --trace --seed 0 --max-failures 1
```

### Finding Issues

```bash
# Check for unused dependencies
mix deps.unlock --check-unused

# Check for unused aliases/imports
mix compile --warnings-as-errors

# Detailed dialyzer output
mix dialyzer --format dialyxir

# Find code smells
mix credo --strict --all
```

## Performance Considerations

### Benchmark Critical Paths

```elixir
# In test file
@tag :benchmark
test "operation performance" do
  {time_microseconds, result} = :timer.tc(fn ->
    MyModule.expensive_operation(input)
  end)

  assert time_microseconds < 1_000_000  # Less than 1 second
end
```

### Profile Memory Usage

```bash
# In iex
:observer.start()  # GUI profiler

# Or programmatically
{time, memory} = :timer.tc(fn ->
  result = MyModule.operation()
  {:erlang.memory(), result}
end)
```

## Working with Dependencies

### Adding Dependencies

```elixir
# In mix.exs
defp deps do
  [
    {:dependency_name, "~> 1.0"},
    {:dev_dependency, "~> 2.0", only: [:dev, :test], runtime: false}
  ]
end
```

```bash
# Install new dependencies
mix deps.get

# Update all dependencies
mix deps.update --all

# Check for outdated deps
mix hex.outdated
```

## Continuous Integration

### Pre-commit Hook

```bash
#!/bin/sh
# .git/hooks/pre-commit

mix format --check-formatted || exit 1
mix credo --strict || exit 1
mix test || exit 1
mix dialyzer || exit 1

echo "✅ All checks passed"
```

### CI Pipeline

```yaml
# Example for GitHub Actions
- name: Run tests
  run: mix test

- name: Check formatting
  run: mix format --check-formatted

- name: Run Credo
  run: mix credo --strict

- name: Run Dialyzer
  run: mix dialyzer

- name: Coverage
  run: mix coveralls.json
```

## Commits and PRs

- Use Conventional Commits: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- Format: `type(scope): subject`
  - Subject: imperative, lowercase, ≤ 72 chars, no trailing period
  - Scope: concise area, e.g. `engine`, `server`, `web`, `docs`, `ci`, `deps`
- Body (optional): explain why and what (not how). Wrap at ~72 chars. Reference issues with `Refs #123` or `Closes #123`.
- Breaking changes: use `type!` or add a `BREAKING CHANGE:` paragraph in the body
- No emojis. No fluff. Keep precise and factual

Examples:

```text
feat(engine): add trick-taking scoring for rounds
fix(server): handle nil player_id in join
docs(readme): clarify setup for dev DB
refactor(web): extract lobby list component
perf(engine)!: replace naive sort with counting sort
```

PRs:

- Small and focused; prefer multiple PRs over one large
- Title follows Conventional Commits (match main change)
- Description: brief context, approach, tests/coverage impact, migrations (if any); link issues
- Checklist: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix dialyzer`, `mix credo --strict`, coverage stable
- Wait for CI green; address review with clear commits; prefer squash-merge using a Conventional Commit title

## Quality Gates

**Code CANNOT be merged unless:**

```bash
# All these exit with 0
mix format --check-formatted  # Code formatted
mix compile --warnings-as-errors  # No warnings
mix test  # All tests pass
mix credo --strict  # No code issues
mix dialyzer  # No type errors
mix coveralls  # Coverage maintained/improved
```

**If any fail, the work is NOT complete.**

## Ralph Methodology Integration

### TODO-Driven Development

```elixir
# In code, use structured TODOs:
# TODO: [PRIORITY] Brief description
# Context: Why needed
# Acceptance: How to validate done
# Refs: Related docs/issues

# Example:
# TODO: [HIGH] Add input validation
# Context: Currently accepts any input
# Acceptance: test/validation_test.exs passes
# Refs: See docs/validation_spec.md
```

### Spec-Driven Implementation

1. **Read the spec** - Check documentation
2. **Write the test** - Encode spec as test
3. **Implement** - Make test pass
4. **Validate** - Run quality checks
5. **Document** - Update `@doc` and commit

## Project Setup

### mix.exs Configuration

```elixir
def project do
  [
    app: :your_app,
    version: "0.1.0",
    elixir: "~> 1.14",
    start_permanent: Mix.env() == :prod,
    aliases: aliases(),
    deps: deps(),

    # Testing
    test_coverage: [tool: ExCoveralls],
    preferred_cli_env: [
      coveralls: :test,
      "coveralls.html": :test
    ],

    # Dialyzer
    dialyzer: [
      plt_add_apps: [:ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  ]
end

defp deps do
  [
    # Quality tools
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
    {:ex_doc, "~> 0.31", only: :dev, runtime: false},
    {:excoveralls, "~> 0.18", only: :test}
  ]
end

defp aliases do
  [
    quality: [
      "format --check-formatted",
      "dialyzer",
      "credo --strict"
    ]
  ]
end
```

**The Golden Rule**: If `mix test && mix dialyzer` passes, you're good. If it doesn't, you're not done.

**Version**: 0.1.0
