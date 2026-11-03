# blackice on npm

Not published yet. When it is:

```console
$ npx blackice install            # download, check and copy Blackice.app to /Applications
$ npx blackice install --force    # replace an installed Blackice.app
$ npx blackice status             # any other command runs Blackice.app's blackice
```

[blackice](https://github.com/ValentinTorassa/blackice) is a headless application firewall for macOS, operated
through a CLI. This package does not contain it. `install` downloads `Blackice-<version>.zip` and its `.sha256` from
the GitHub release whose version matches this package's, and then:

1. checks the zip's SHA-256 against the `.sha256` file;
2. unpacks it with `ditto` into a temporary folder and checks that it holds only `Blackice.app`;
3. checks the app with `codesign --verify --strict --deep`, checks with `codesign -dvv` that it is signed as
   `com.valentorassa.blackice` with a Developer ID Application certificate of team M294LK997M, and checks that
   `spctl --assess --type execute` accepts it with `source=Notarized Developer ID`;
4. copies it to `/Applications` with `ditto`, refusing to replace an installed copy without `--force`, and prints the
   next steps.

It does not activate the network extension or load the daemon: `blackice start` and `blackice agent install` do, as
the [install guide](https://github.com/ValentinTorassa/blackice/blob/main/docs/install.md) describes. After
replacing an installed copy, run `blackice start` and restart the Mac.

Every other command runs `/Applications/Blackice.app/Contents/MacOS/blackice` by its full path with the same
arguments. A symbolic link to that binary does not work: the commands that need the signed app refuse to run
through one.

The package has no dependencies and no install scripts; it uses Node's own modules and the macOS tools in
`/usr/bin` and `/usr/sbin`. It needs macOS on Apple silicon, like Blackice.app, and Node 18 or later.

## Tests

```console
$ npm test
```

The tests cover what needs no network and no Mac: the release URLs, the checksum file, the signature and Gatekeeper
checks on sample output, the arguments, and the package's own manifest.

## License

Apache-2.0, as the rest of the repository.
