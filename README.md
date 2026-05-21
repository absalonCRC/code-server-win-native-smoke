# code-server Windows Native Smoke Package

This repository builds a Windows x64 smoke package for `code-server` using GitHub Actions on a native Windows runner.

The package includes:

- portable `node.exe`
- `code-server` installed from npm
- `start-code-server.cmd`
- smoke-test logs and SHA-256 checksum

The workflow verifies:

- `start-code-server.cmd --version` exits successfully
- `code-server` starts on `127.0.0.1`
- the local HTTP endpoint returns status 200

This is intended as delivery evidence for coder/code-server issue #7198.
