# Coding Conventions

- Preserve invariants through the type system whenever possible.

- All type class instances must be explicitly named.

- Any expression that may, at runtime, produce values that do not conform to the type inferred by the PureScript compiler (e.g., through FFI) must be prefixed with `unsafe`.

- Expressions named `unsafeXX` according to the above convention should, wherever possible, not be exported directly. Instead, they should be wrapped in expressions whose safety is guaranteed by the type system, and only the safe API should be exported.

- Comments must follow these guidelines:
  - Comments in source code must be written in English.
  - Comments should explain **why** something is done, not **what** it does.
    Code should be written to be as self-descriptive as possible, making "what" comments unnecessary in principle.
    However, when an implementation must be made unusually complex due to performance optimizations, workarounds for bugs in external dependencies, or other unavoidable reasons, comments should explain the rationale behind such implementations.

- Test code must follow these guidelines:
  - Under the `{package}/tests` directory, create `Unit` and `E2E` subdirectories, and place unit tests and end-to-end/integration tests in the corresponding directories.
  - Create a unit test module for each module under `src`. Test modules should be named using the pattern `Test.{target module name}`.

    - Example: The unit test module for `Foo.Bar` should be named `Test.Foo.Bar`.
  - Define separate commands for unit tests and end-to-end tests in `package.json`, as shown below:

    ```json
    {
      "scripts": {
        "test:unit": "spago test",
        "test:e2e": "spago test -m Test.E2E.Foo"
      }
    }
    ```

    This example assumes that `test.main` in `spago.yaml` is set to `Test.Unit.Foo`.
