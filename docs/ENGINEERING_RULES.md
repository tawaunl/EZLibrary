# SeratoTools Engineering Rules

These rules apply to all new code in this repository.

## User-Readable Errors (Required)

When creating a new error type, always make it user-readable.

Rules:

- Do not rely on default enum error descriptions like `...error 1`.
- Error types intended to surface in UI must conform to `LocalizedError`.
- Provide a clear `errorDescription` that explains what failed in plain language.
- Provide `recoverySuggestion` when there is a practical next step.
- Include relevant context in messages (file name/path, operation, track/crate identity) when safe.
- Keep internal-only details out of user-facing messages.

Swift pattern:

```swift
enum ExampleError: Error, LocalizedError {
    case itemNotFound(String)
    case appIsRunning

    var errorDescription: String? {
        switch self {
        case let .itemNotFound(name):
            return "Could not find item: \(name)."
        case .appIsRunning:
            return "Close Serato and try again."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .itemNotFound:
            return "Reload the library and retry."
        case .appIsRunning:
            return "Quit Serato DJ, then retry the operation."
        }
    }
}
```

Review checklist (required for PRs touching error types):

- Every new user-facing error conforms to `LocalizedError`.
- Every new user-facing error has a meaningful `errorDescription`.
- UI surfaces `localizedDescription` (or equivalent) from those errors.
