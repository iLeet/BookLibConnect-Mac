# Book Lib Connect for Mac

A native macOS port of [Book Lib Connect](https://github.com/audiamus/BookLibConnect) by audiamus — a standalone Audible downloader and decrypter. Same windows, same options, same workflow, rebuilt in SwiftUI with Liquid Glass.

- Sign in through your regular browser to register a *device*; the app never sees your credentials.
- Lists your library and lets you pick titles to download.
- Downloads and converts books to plain `.m4b` (chapters and tags included, ready for Apple Books).
- Optionally exports `.aax` files plus chapter/product JSON for [AAX Audio Converter](https://github.com/audiamus/AaxAudioConverter).
- Multi-part books, quality choice (Normal / High), profiles for several accounts and regions.

Requires macOS 26 (Tahoe) or later — developed on macOS 27.

## Download

Grab the latest `Book-Lib-Connect-*.zip` from the [Releases](../../releases) page, unzip, and drag **Book Lib Connect** to Applications. The app is ad-hoc signed, not notarized: on first launch right-click → Open, or run `xattr -cr "/Applications/Book Lib Connect.app"`.

## Build

```bash
Scripts/build-app.sh            # release build -> build/Book Lib Connect.app
UNIVERSAL=1 Scripts/build-app.sh   # arm64 + x86_64
swift test                      # unit tests
```

The app is ad-hoc signed. Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for distribution.
Try the interface without an account: `BLC_DEMO=1 "build/Book Lib Connect.app/Contents/MacOS/BookLibConnect"`.

## What changed from the Windows version

| Windows (.NET 8 / WinForms) | macOS |
| --- | --- |
| AAXClean decryption | `AAXCRemuxer`: per-sample AES-128-CBC decryption and MP4 rewrite in Swift (CommonCrypto) |
| EF Core / SQLite book database | JSON store in `~/Library/Application Support/BookLib­Connect-Mac` |
| Config encrypted with CPU/board IDs | AES-GCM with a key in the macOS Keychain |
| DataGridView, dialogs | SwiftUI `Table`, sheets, Liquid Glass panels |
| Online updater, Windows installer | not ported; build from source |

The original C# sources are kept under [`legacy-windows/`](legacy-windows) for reference.

## Where data is stored

- Profiles: `~/Library/Application Support/BookLibConnect-Mac/config/Configuration.json` (encrypted), key in the Keychain item `com.booklibconnect.mac.config`
- Library database and covers: `~/Library/Application Support/BookLibConnect-Mac/`
- Settings: `defaults` domain `com.github.ileet.BookLibConnect-Mac`

## Roadmap

See [docs/ROADMAP.md](docs/ROADMAP.md).

## Layout

- `Sources/BookLibCore` — Audible auth/signing, API client, library store, download, AAXC → m4b remuxer, AAX exporter.
- `Sources/BookLibConnect` — the SwiftUI app.
- `Tests/BookLibCoreTests` — signing, voucher, PKCE, and remuxer tests (including a bit-exact decode check through ffmpeg when installed).

## Anti-piracy notice

This software does not crack or circumvent DRM. It applies account- and book-specific keys, retrieved from the Audible server through your own account, to decrypt audiobooks the same way the official player does. Use it only for your own audiobooks, for archiving and convenience. De-DRMed audiobooks must not be uploaded or distributed. Authors, narrators and publishers need to make a living.

## Acknowledgments

- [audiamus](https://github.com/audiamus/BookLibConnect) for the original application and its design.
- [mkb79](https://github.com/mkb79/Audible), [Mbucari](https://github.com/Mbucari/AAXClean) and [rmcrackan](https://github.com/rmcrackan/AudibleApi) for the reference implementations the original builds on.

## License

GNU GPL v3, as the original — see [LICENSE](LICENSE).
