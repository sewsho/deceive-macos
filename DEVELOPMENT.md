# Development

## Building

Requires Xcode and macOS 13 or later.

```sh
./scripts/build-app.sh      # produces build/Deceive.app (universal, ad-hoc signed)
swift test
```

Optional live test of the certificate and network path (TLS handshake, bridge to Riot chat, clientconfig fetch):

```sh
curl -o /tmp/localhost.pfx https://mln.cx/deceive/localhost.pfx
DECEIVE_TEST_PFX=/tmp/localhost.pfx DECEIVE_INTEGRATION=1 swift test
```

## Releasing

Pushing a `v*` tag builds the app on GitHub Actions and publishes it as a release with `Deceive-macOS.zip`:

```sh
git tag v1.0.1 && git push origin v1.0.1
```

Tags with a suffix, such as `v1.1.0-beta.1`, are published as pre-releases, which the in-app update check ignores.

## Command-line options

```sh
Deceive.app/Contents/MacOS/Deceive [lol|tft|riotclient|prompt|auto] \
    [--game-patchline live] [--riot-client-params "..."] [--game-params "..."]
```

## How it works

Deceive launches the Riot Client with a local `--client-config-url`. The config proxy rewrites the chat servers
to `deceive-localhost.molenzwiebel.xyz` (which resolves to 127.0.0.1) and a local port. A TLS proxy on that port
forwards chat to the real server, rewriting your outgoing presence and injecting the "Deceive Active!" friend.

| File | Upstream equivalent | Purpose |
|---|---|---|
| `ConfigProxy.swift` | `ConfigProxy.cs` | Proxies and rewrites clientconfig |
| `ChatProxy.swift`, `ProxiedConnection.swift` | `MainController.cs`, `ProxiedConnection.cs` | TLS chat proxy |
| `PresenceRewriter.swift` | `ProxiedConnection.cs` | Presence rewriting |
| `MainController.swift` | `MainController.cs` | Menu bar and chat commands |
| `StartupHandler.swift` | `StartupHandler.cs` | Startup and launching the Riot Client |
| `Utils.swift`, `ProxyCertificate.swift` | `Utils.cs` | Processes, updates, certificate |

## Differences from the Windows version

- **Certificate:** `localhost.pfx` can't be imported by macOS as-is. It uses an empty password with RC2
  encryption, and its EC private scalar is 31 bytes instead of 32. Deceive decrypts it with the system
  `/usr/bin/openssl` (LibreSSL), rebuilds the key, and creates the TLS identity in memory. Nothing is added to
  the keychain.
- **Split presences:** a presence split across two TLS reads is buffered until complete, instead of being dropped.
- **Status saving:** the status is saved whenever it changes, so "Remember Last" also works when Deceive exits
  with the Riot Client.
- **Games:** only League of Legends, Teamfight Tactics and the Riot Client.

## Keeping up with upstream

This port is based on upstream commit `6328f1d`. To see what changed upstream since then:

```sh
git remote add upstream https://github.com/molenzwiebel/Deceive.git
git fetch upstream
git log --oneline 6328f1d..upstream/master -- Deceive/
```

Port the relevant changes, then update the commit hash above.
