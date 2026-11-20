# Hesper for Windows (preview)

A tray app (C# / .NET 8, WinForms, NAudio) around the same Python engine as the Mac app.

- `Recorder.cs`: microphone + PC sound (WASAPI loopback) → `mic.wav` / `system.wav`, 16 kHz mono,
  one timeline. Windows' default devices (not the "communications" ones), or the ones chosen in Settings.
- `EngineRunner.cs`: `python -m hesper …` with Hesper's environment; reads `@@step` / `@@progress`.
- `Setup.cs`: first launch into `%LOCALAPPDATA%\Hesper`: the engine (inside the exe), uv, Python 3.12,
  `uv sync --frozen [--extra cuda]`, llama.cpp (CUDA or CPU build), `hesper setup` for the models.
  uv and llama.cpp are pinned and checked by SHA-256. No admin rights, nothing system-wide.
- `TrayApp.cs`, `SettingsForm.cs`, `Settings.cs` (settings.json → config.toml), `Brand.cs` (the icon).

Build, with the .NET 8 SDK (a portable one is fine):

```powershell
cd win\Hesper
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=none -o ..\dist
```

Tests without the tray: `Hesper.exe --record SECONDS [NOTES_FOLDER] [MIC_NAME]` records then makes the
notes; `Hesper.exe --devices` lists the default devices and how loud each one is (for support);
`Hesper.exe --write-icon Hesper.ico` redraws the icon. `HESPER_HOME` moves the data folder (a test setup).

Publishing, as `scripts/release.sh` for the Mac (the .NET 8 SDK and `gh auth login` once):

```powershell
.\scripts\release_windows.ps1 "What's new"     # prepare: build-cache\windows\Hesper-X.exe + latest-windows.json
.\scripts\release_windows.ps1 -Publish         # push main, the exe on release vX, then the feed + models.json
```

`-Beta` (with either) makes a test version for `latest-windows-beta.json`. The version is pyproject's,
the build number one more than the feeds'; it is the exe's 4th version number, which the updater
compares. The site's Windows button turns on with `latest-windows.json`. The exe isn't code-signed
yet: SmartScreen warns on the first download.

Diagnostics: `Hesper.exe --calendar` (what Hesper reads from Outlook), `--devices`, `--capture DIR`
(PNGs of every screen, light and dark), `--record SECONDS [FOLDER] [MIC] [process:NAME]`, `--notify`
(a test notification, and whether Windows lists Hesper in Settings → Notifications).

Recordings are written in `%LOCALAPPDATA%\Hesper\recordings` and move to the notes folder once
processed (a OneDrive folder never gets audio being written); one not processed (Hesper quit,
crashed, updated) is processed at the next launch. Hesper's app ID (`Gbally.Hesper`, with a
Start menu shortcut) is what Windows lists its notifications under. A test setup (`HESPER_HOME`) runs
beside the real Hesper; `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9333` lets a
script drive its pages.
