# blackice

Local network permissions for apps and agent tasks. See the [project](https://github.com/ValentinTorassa/blackice) for supported backends and recorded limits.

This package contains a small Node.js launcher. Its four optional platform packages are pinned to exactly the same version and supply the native release binary. There are no install scripts, downloads at runtime, or other runtime dependencies. Node.js 22 or later is required for this launcher.

Once this version is published, install the exact version with optional dependencies enabled:

```sh
npm install --global --ignore-scripts {{NAME}}@{{VERSION}}
blackice version
```

On Linux, the matching platform package also contains the privileged-helper setup bundle as data. Read that package's README, verify the release provenance and run setup manually. npm never runs setup, sudo or setcap.

The launcher preserves command arguments, standard input/output/error and numeric exit status. A binary terminated by a signal causes the launcher to re-emit that signal. Terminal signals reach the shared foreground process group. A signal sent only to the Node launcher PID is not forwarded while `spawnSync` blocks; supervisors must signal the process group or run the native binary directly.

Missing or mismatched platform packages produce an error. The launcher never downloads a replacement or falls back to a binary on PATH.
