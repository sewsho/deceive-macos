# 🎭 Deceive for macOS (unofficial)

Appear offline in League of Legends and Teamfight Tactics on your Mac, while still being able to play and chat
in lobbies.

This is an unofficial Mac port of [Deceive](https://github.com/molenzwiebel/Deceive) by molenzwiebel. Please
report Mac problems [here](https://github.com/sewsho/deceive-macos/issues), not on the original project.

## Install

1. Download `Deceive-macOS.zip` from the [latest release](https://github.com/sewsho/deceive-macos/releases/latest).
2. Unzip it and drag `Deceive.app` into your Applications folder.
3. Open Deceive. The first time, macOS will block it; see
   [the FAQ](#macos-says-apple-could-not-verify-deceive-what-do-i-do) for the one-time fix.

## How to use

Open Deceive instead of League. It starts the game for you and puts a 🎭 icon in your menu bar. You now appear
offline.

Click the menu bar icon to switch between Online, Offline and Mobile, or to turn Deceive off. You can also send
`online`, `offline`, `mobile` or `help` to the "Deceive Active!" friend in your friends list.

## FAQ

### macOS says "Apple could not verify Deceive". What do I do?

Deceive isn't notarized by Apple (that requires a paid developer account), so macOS blocks it the first time. Click **Done**, open
**System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

### Can I still invite people? Can they invite me?

You can invite everyone as normal. Your friends cannot invite you while you appear offline, even if they type
your name. If you need an invite, turn Deceive off in the menu bar, then back on once you're in the lobby.

### Can I talk in lobbies and champion select?

Yes. Only your status in the friends list is hidden. You can turn off lobby chat in the menu bar if you want.

### Does it work for VALORANT or Legends of Runeterra?

No. VALORANT, Legends of Runeterra and 2XKO don't run on macOS. Deceive for macOS supports League of Legends,
Teamfight Tactics and the Riot Client.

### Can I get banned?

Riot [confirmed](https://i.thijsmolendijk.nl/deceive_ok.png) that you won't get banned for using Deceive. That
statement was about the original Windows version; this Mac port works exactly the same way. It may stop working
whenever Riot changes something.

### Deceive says it is "failing to resolve some required domains".

Your network is blocking a domain Deceive needs. Switch your DNS to [1.1.1.1](https://one.one.one.one/dns/) or
8.8.8.8, or add this line to `/etc/hosts`:

```
127.0.0.1 deceive-localhost.molenzwiebel.xyz
```

### Does it work on Intel Macs?

Yes. Deceive runs on both Apple silicon and Intel Macs with macOS 13 Ventura or newer.

### It stopped working.

Riot sometimes changes things that break Deceive. Deceive tells you when an update is available. If you're on
the latest version and it still doesn't work, [open an issue](https://github.com/sewsho/deceive-macos/issues).

### How do I uninstall it?

Delete `Deceive.app`, and optionally the folder `~/Library/Application Support/Deceive`.

## License

GPL-3.0. This is a modified version of [Deceive](https://github.com/molenzwiebel/Deceive) by Thijs Molendijk
(molenzwiebel), ported to Swift for macOS by me. It uses the original project's
certificate and domain [with permission](https://github.com/molenzwiebel/Deceive/issues/326).
