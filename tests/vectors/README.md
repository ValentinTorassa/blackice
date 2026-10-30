# Sandbox import vectors

`sandbox-import-v1.json` is synthetic test data for `blackice.sandbox-subset/v1`. It contains 63 accepted and rejected inputs. Source patterns use documentation domains and addresses; the credential-looking transform value is explicitly synthetic and must be rejected without echoing it.

Run from the repository root:

```sh
zig test src/core/sandbox_import.zig
```

Accepted cases check normalized names and selected destination decisions. Rejected cases cover unsupported handling, unknown/duplicate fields, wildcard forms, invalid names and noncanonical or unsupported CIDRs. Additional Zig tests cover the activation capability gate, input-buffer lifetime, parser bounds and every allocation-failure point.

The capability flags used in these tests are synthetic. Results establish software conversion behavior only; they are not Vercel-cloud comparisons, kernel-enforcement tests or native release evidence. See [the policy contract](../../docs/policy.md) for source references and supported scope.
