<p align="center">
  <img src="MacApp/Resources/MusicBridgeIcon.png" width="128" alt="Music Bridge — silver IPC3 icon">
</p>

# Music Bridge

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

A native macOS tool for organizing and importing music for iPod / Rockbox lovers.

It works like this: paste a playlist link, connect your own local download tools, then import the music into your iPod by hand. The interface is built with SwiftUI, system fonts and SF Symbols; the icon is a silver IPC3.

**Currently a source-only beta.** Building, launching, the icon and the no-device interface have been verified on Apple Silicon, macOS 27.2. The full download chain depends on external services and your own local setup, and has not been end-to-end verified as a public release. Start with a few files and a backed-up device.

## What problem this solves

Getting music onto an iPod today is a scattered chore:

- The stock route needs iTunes or Finder sync and is picky about formats. Rockbox removes the format problem, but finding, downloading and importing songs are still three separate jobs;
- Your playlists probably live on NetEase Cloud Music, while real lossless audio lives on Apple Music. The two do not line up, and matching songs one by one by hand is miserable;
- The tools that can download Apple Music lossless are mostly command-line, and need a signed-in decryption service configured by hand;
- Copying files onto the iPod afterwards is yet another job, with album art and playability to watch.

Music Bridge is the dispatch desk that connects this chain: a playlist link comes in, it handles matching, hands off the download, and finally sends the files into the iPod. It stores no music itself, ships no downloader, and never touches your account. Your account signs in only inside the wrapper service on your own machine; the app only talks to that local service. More of a bridge — hence the name.

Four things are designed this way on purpose:

- **Accounts stay out of it.** Sign-in happens inside wrapper-lite. The app only talks to a local address, `127.0.0.1:12340`, to ask for status and hand over jobs. It never sees your password.
- **Import is always manual.** Nothing is written to the iPod automatically — not when a download finishes, not when a device connects. Files are copied only when you click "Start Import", which leaves you a moment to check the download folder first.
- **Import comes with a health check.** Before and after copying, every file is probed with ffprobe: can it be parsed, are codec and bitrate right, is artwork present. Afterwards you get a report — how many imported, how many skipped, how many have problems, all written down.
- **Downloads and imports stay flat.** A downloaded playlist lands flat in a single folder named after the playlist — no artist/album nesting. On import, a folder with the same name is created under `Music` on the iPod, songs are numbered in playlist order, and each song gets a same-name `.jpg` cover beside it.

## Beginner's guide: run it once, end to end

For your first run you need four things: a Mac (verified on Apple Silicon); a working Apple Music subscription; the two download tools, amdl and wrapper-lite (see "Configure the local download tools" below); and an iPod running Rockbox, already backed up.

1. **Get the app running.** Build and open it as described in "Build and launch". If the window appears, step one is done.
2. **Start wrapper-lite and sign in.** In the wrapper-lite folder, follow its own instructions to run the login script and sign in with your Apple ID. The login state lives only on your machine.
3. **Fill in Connection Settings.** Open "Connection Settings…" (`⌘,`), and enter the amdl path, the download working directory (it must contain `config.yaml`), and the wrapper address (default `http://127.0.0.1:12340`).
4. **Set the download quality now — do not skip this.** Open `config.yaml` in the working directory and change `alac-max` to `48000`. This caps downloaded lossless files at 48 kHz. It pairs perfectly with the Rockbox Ultimate firmware from my other repo — that machine is happiest with files up to 48 kHz, and higher sample rates actually stutter on it. If you only listen on the computer, you can ignore this step.
5. **Practice on a small playlist.** Pick a NetEase or Apple Music playlist with few songs, paste the link into the main window, start the download, and watch the log. Matching looks songs up in the Apple Music China catalog by their metadata; versions that cannot be confirmed are skipped, and the log says so.
6. **Import to the iPod.** Plug the iPod in and wait for the device card to show it is ready. Glance through the download folder to confirm it holds what you want, then click "Start Import". Read the report afterwards: how many imported, how many skipped as already present, whether any file is unplayable.
7. **Eject and listen.** Play a few songs start to finish. If they play clean, the chain works. From then on it is a three-step loop: paste link, download, import.

If something breaks, check these two first: downloads that never start usually mean the wrapper is not running or its login expired — confirm `http://127.0.0.1:12340` responds. If "Start Import" cannot be clicked, the device was not recognized — check the iPod contains `.rockbox` or `iPod_Control`, and that the `Music` folder is writable.

## Let Codex set it up for you

The seven steps above are fine to walk yourself, just tedious. You can also paste the following into Codex (or any AI agent that can work on your computer) and let it walk you through the setup. It cannot sign in for you — it will stop at that step and hand it to you. That is intentional.

> Help me set up Music Bridge on this Mac. The repo is https://github.com/ZexinLiu725/music-bridge — read its README first, then follow these steps in order and report back after each one. Do not skip steps.
>
> 1. Check the environment: macOS version, chip, Swift version, Xcode Command Line Tools, and whether ImageMagick and ffmpeg (ffprobe) are installed. Tell me what is missing and ask before installing anything.
> 2. Clone the repo, build it as described in the README, run the verify script, and open the app so I can see it. Note any build warnings; do not change code to silence them.
> 3. Prepare the download tools: install amdl (https://github.com/zhaarey/apple-music-downloader) and wrapper-lite (https://github.com/WorldObservationLog/wrapper/tree/lite) following their own repos. The wrapper requires an Apple ID sign-in: stop there and let me run the login script myself in Terminal. Never ask for my account, password, or verification codes, and never type them for me.
> 4. After I confirm I am signed in, check that the wrapper service answers at http://127.0.0.1:12340, then walk me through Music Bridge's Connection Settings and fill in the amdl path, the download working directory, and the wrapper address.
> 5. In the working directory's config.yaml, back the file up first, then set alac-max to 48000 and save. This caps lossless downloads at 48 kHz, because I import into an iPod running the Rockbox Ultimate firmware, which plays files up to 48 kHz most reliably.
> 6. Test with a small playlist first: I will give you the link; run the download, watch the log, and tell me how many songs matched, how many were skipped, and why.
> 7. Always ask me before importing to the iPod, and only click "Start Import" after I explicitly agree. Afterwards, read me the report: how many imported, how many already existed, how many are unplayable. Stop and ask before anything overwrites or deletes files on the device.

## What it can do

- Recognize NetEase Cloud Music playlists and public Apple Music playlist links.
- Match NetEase song metadata to Apple Music; versions that cannot be confirmed are skipped.
- Start downloads through your own `amdl` and wrapper-lite, showing status, progress and logs.
- Show the iPod's connection state at all times; import only becomes available when a writable device is connected.
- Manually scan the download directory, copy files into the device's `Music` folder, preserving the folder structure and the sidecar `cover.jpg`.
- Use `ffprobe` to check whether a file parses, plus its codec, bitrate and embedded artwork.

Downloads finishing and devices connecting never trigger an import automatically. Files are copied only when you click "Start Import".

## Build and launch

Building requires macOS, Swift 6 or newer, and developer tools with the macOS 27 SDK. The source runs on macOS 14 at minimum, with a compatibility interface on older systems; the verified environment is macOS 27.2.

Install the Apple developer tools and ImageMagick, then run in the repo root:

```bash
brew install imagemagick
swift build --package-path MacApp
bash script/build_and_run.sh --verify
```

The script generates and opens `dist/MusicBridgeApp.app` and packages the official icon. You can also just build the Swift package, or use `bash script/build_and_run.sh --logs` to see system logs.

This build has no Developer ID signing or notarization, and there is no ready-to-install release package.

## Configure the local download tools

This repo contains only the macOS app — no downloader, no login environment. Install the download tools separately, following their own projects:

- [amdl](https://github.com/zhaarey/apple-music-downloader)
- [wrapper-lite](https://github.com/WorldObservationLog/wrapper/tree/lite)

In Music Bridge's menu, open "Connection Settings…" (`⌘,`), and fill in:

1. The absolute path of the `amdl` executable.
2. The downloader's working directory, which must contain your own `config.yaml`.
3. The wrapper-lite service address, default `http://127.0.0.1:12340`.
4. An optional wrapper start script; leave empty if the service is already running.

These paths are stored in the app's preferences on this machine. Account sign-in and credentials are configured in the external tools — never commit such data to this repo.

## Importing to the iPod

Back up your device first, then connect a mounted, writable Rockbox iPod. The device must have a `Music` folder, plus either `.rockbox`, or `iPod_Control`.

Import scans the audio directory from your settings and folders whose names start with `AM-DL` in the working directory. Before clicking "Start Import", make sure those folders only contain what you actually want copied.

**Files with the same path and size are skipped; same-name targets with a different size are replaced.** De-duplication looks at path and size only — two files of equal size are not guaranteed to have identical content. Import cannot be cancelled midway, and there is no rollback for device files.

Media checks need `ffprobe` to be findable in the app's runtime environment. Install it with `brew install ffmpeg`; if it is not found when launching from Finder, check the `PATH` the app inherits.

One more note: a sidecar `cover.jpg` and artwork embedded in the audio file are two different checks. An embedded-artwork pass in the report says nothing about how covers browse in Rockbox.

## Known limits and privacy

- NetEase links are sent to the third-party GoMusic service; Apple Music matching talks to Apple's web and catalog endpoints. If those services change, the related features may break.
- Matching uses the Apple Music China catalog; cross-region or different releases are not guaranteed to match exactly.
- wrapper-lite must be signed in locally and return a correct `/status` response; the app provides no account and no subscription.
- The icon is a static `.icns`; it does not use Icon Composer's dynamic system refraction.
- Only process music you have the right to access. This repo contains no music, no downloader, no login data, and no authorization for any third-party service.

## Changing the icon

`MusicBridgeArtwork.png` is the IPC3 body artwork, `MusicBridgeIcon.svg` handles the rounded corners, padding and layout, and `MusicBridgeIcon.png` is the official export used by builds.

After changing the artwork or layout, run `node script/render_icon.cjs` in an environment with Node.js and `sharp` to re-export. Normal builds use the exported PNG and do not need Node.js. The per-size `.iconset` is generated in a temporary directory only and cleaned up after packaging.

## Feedback and license

Issues and Pull Requests are welcome. When reporting a problem, include your macOS version, device model, steps to reproduce, and redacted error details; do not attach account credentials, full configs, private music, or unredacted logs.

This repo is under the [MIT License](LICENSE). Sources for external tools, services, trademarks and assets are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
