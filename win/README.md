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

Publishing: attach `Hesper.exe` to the GitHub release, then put `latest-windows.json` (version, build,
url, sha256, notes) at the repository root; the site's Windows button turns on when it's there.
The exe isn't code-signed yet: SmartScreen warns on the first download.
