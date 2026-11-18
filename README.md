# Claude Accounts for Windows

Download **Makefile.exe** from [Releases](../../releases) and double-click it. Setup places the app and its step-by-step guide in the **Claude Accounts** folder on your desktop and opens that folder. Start **Claude Accounts.exe**. The portable ZIP contains the same app and guide.

Requires Windows x64 and Claude Desktop's Microsoft Store (MSIX) build. Existing profiles from Sevin47's switcher are picked up under the same Windows user. The Accounts tab saves and switches profiles. The Sessions tab copies a local Claude Code session to the other account. See [the guide](START%20HERE%20-%20Windows%20Guide.txt).

## Build

Run `make` with Go, make, zip and a POSIX shell. The Windows binaries and portable ZIP appear in `dist/`. The executables are unsigned. A live Windows account switch has not been tested for this build.

Adapted from [Sevin47/claude-desktop-switcher](https://github.com/Sevin47/claude-desktop-switcher) under the [MIT license](LICENSE).
