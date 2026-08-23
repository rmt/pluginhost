# Vendored CLAP headers

This directory contains the official CLAP headers and license from the
`free-audio/clap` **1.2.10** tag.

- Upstream: <https://github.com/free-audio/clap>
- Tag: `1.2.10`
- Commit: `195b42a004144fab0b3cf95e9c067187d15365b7`
- `include/clap` Git tree: `4ea708cc21ea6be4489fd136fa50498baab8b7b4`
- License: MIT; see `LICENSE`

The complete upstream header tree is preserved so its provenance can be checked
without reconstructing a filtered SDK. It includes upstream draft headers, but
pluginhost does not bind, include, advertise, or otherwise expose draft
extensions in its supported ABI surface.

To verify this copy against an upstream checkout:

```sh
rm -rf /tmp/clap-verify && mkdir -p /tmp/clap-verify
git -C /path/to/clap archive --format=tar 1.2.10 include/clap LICENSE |
  tar -xf - -C /tmp/clap-verify
diff -ru /tmp/clap-verify/include/clap vendor/clap/include/clap
diff -u /tmp/clap-verify/LICENSE vendor/clap/LICENSE
```

An SDK update requires a deliberate version/provenance update, an audit of all
bound declarations, and passing C-versus-Nim ABI tests before acceptance.
