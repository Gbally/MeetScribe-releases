# Releases the Windows app in two steps, as scripts/release.sh does for the Mac:
#
#   .\scripts\release_windows.ps1 "What's new"   PREPARE (local only): builds Hesper.exe and writes
#                                                 build-cache\windows\ (Hesper-X.exe, latest-windows.json).
#   .\scripts\release_windows.ps1 -Publish        PUBLISH: pushes main, adds the exe to the GitHub release
#                                                 vX (creating it if the Mac hasn't), then commits
#                                                 latest-windows.json + models.json and pushes them.
#                                                 Installed apps offer the update within a day.
#
#   -Beta (with either step)                      a TEST version: "0.7.0-test.N", a GitHub pre-release and
#                                                 latest-windows-beta.json, offered only to apps with
#                                                 Settings -> About -> "Receive test versions" on.
#
# The version is pyproject.toml's; the build number goes up by one from the feed's. Needs the .NET 8
# SDK (dotnet on PATH, or MeetScribe\tools\dotnet) and the GitHub CLI logged in once (gh auth login).
param([string]$Notes = "", [switch]$Publish, [switch]$Beta)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$Root = (Get-Location).Path
$Repo = "Gbally/Hesper"
$Feed = if ($Beta) { "latest-windows-beta.json" } else { "latest-windows.json" }
$Out = Join-Path $Root ("build-cache\windows" + $(if ($Beta) { "-beta" } else { "" }))

function Find-Tool($name, $fallbacks) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($f in $fallbacks) { if (Test-Path $f) { return $f } }
    return $null
}
$Tools = Join-Path (Split-Path $Root) "tools"
$Gh = Find-Tool "gh" @("$Tools\gh\bin\gh.exe", "$env:ProgramFiles\GitHub CLI\gh.exe")
# The portable .NET SDK first: the dotnet on PATH is often the runtime alone (no SDK, "publish" doesn't exist)
$Dotnet = if (Test-Path "$Tools\dotnet\dotnet.exe") { "$Tools\dotnet\dotnet.exe" } else { Find-Tool "dotnet" @() }
# The portable gh keeps its login next to it (gh auth login with the same GH_CONFIG_DIR), not in %APPDATA%
if ($Gh -and $Gh.StartsWith($Tools)) { $env:GH_CONFIG_DIR = "$Tools\gh\config" }
# The portable SDK's caches and NuGet packages stay next to it too, as win\env.sh sets them
if ($Dotnet -and $Dotnet.StartsWith($Tools)) {
    $env:DOTNET_ROOT = "$Tools\dotnet"; $env:DOTNET_CLI_HOME = "$Tools\dotnet-home"; $env:NUGET_PACKAGES = "$Tools\nuget"
    $env:DOTNET_NOLOGO = "1"; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
}

function Read-Feed($path) { if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { $null } }

if (-not $Publish) {
    if (git status --porcelain) { throw "Commit your changes first." }
    if (-not $Dotnet -or -not (& $Dotnet --list-sdks)) { throw "The .NET 8 SDK isn't installed (dotnet, or MeetScribe\tools\dotnet)." }
    $Version = (Select-String -Path pyproject.toml -Pattern '^version = "(.*)"').Matches[0].Groups[1].Value
    # The next build number: one more than the release and test feeds published so far
    $Builds = @("latest-windows.json", "latest-windows-beta.json") | ForEach-Object { (Read-Feed $_).build } | Where-Object { $_ }
    $Build = ([int]($Builds | Measure-Object -Maximum).Maximum) + 1
    $Label = if ($Beta) { "$Version-test.$Build" } else { $Version }
    $Exe = "Hesper-$Label.exe"
    if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
    New-Item -ItemType Directory -Force $Out | Out-Null
    Write-Host "- Building Hesper $Label (build $Build)"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    & $Dotnet publish win\Hesper -c Release -r win-x64 --self-contained -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=none `
        -p:Version="$Version.$Build" -o "$Out\bin" | Select-String -Pattern "error|Hesper ->"
    if ($LASTEXITCODE -ne 0) { throw "The build failed." }
    Move-Item "$Out\bin\Hesper.exe" "$Out\$Exe"
    Remove-Item -Recurse -Force "$Out\bin"
    $Sha = (Get-FileHash "$Out\$Exe" -Algorithm SHA256).Hash.ToLower()
    if (-not $Notes) { $Notes = "Hesper $Label" }
    $Info = [ordered]@{ version = $Label; build = $Build; url = "https://github.com/$Repo/releases/download/v$Label/$Exe"; sha256 = $Sha; notes = $Notes }
    [IO.File]::WriteAllText("$Out\$Feed", ($Info | ConvertTo-Json))  # UTF-8 without BOM, as the Mac's feeds
    [IO.File]::WriteAllText("$Out\commit.txt", (git rev-parse HEAD))   # what PUBLISH checks it pushes
    Write-Host ""
    Write-Host "OK: Prepared Hesper $Label (build $Build) in $Out - nothing published."
    Write-Host ("   Publish with:  .\scripts\release_windows.ps1 -Publish" + $(if ($Beta) { " -Beta" } else { "" }))
    exit 0
}

# --- publish (uses what PREPARE produced)
$Info = Read-Feed "$Out\$Feed"
if (-not $Info) { throw ("Run .\scripts\release_windows.ps1" + $(if ($Beta) { " -Beta" } else { "" }) + " (prepare) first.") }
if (-not $Gh) { throw "The GitHub CLI isn't installed (gh), or isn't on PATH." }
if ((git rev-parse --abbrev-ref HEAD) -ne "main") { throw "Publish from the main branch." }
$Label = $Info.version
$Exe = "Hesper-$Label.exe"
# git and gh write to stderr even when all is well: with "Stop", Windows PowerShell 5 would end the
# script on the first line (gh's "release not found"). Their exit codes are checked instead.
$ErrorActionPreference = "Continue"

# The exe must be built from the code that's pushed: no change to it since PREPARE.
$Built = Get-Content "$Out\commit.txt" -ErrorAction SilentlyContinue
git diff --quiet $Built HEAD -- src win pyproject.toml uv.lock catalog 2>$null
if (-not $Built -or $LASTEXITCODE -ne 0) { throw "The code changed since the exe was built: prepare again (.\scripts\release_windows.ps1 `"What's new`")." }

# 1. The code the release is built from.
Write-Host "- Pushing main"
git push -q origin main
if ($LASTEXITCODE -ne 0) { throw "main couldn't be pushed (GitHub has newer commits?): git pull, prepare again, then publish. Nothing was published." }

# 2. The exe on the release vX (the Mac's DMG may already be there).
& $Gh release view "v$Label" --repo $Repo *> $null
if ($LASTEXITCODE -eq 0) {
    # The asset's digest, read here (Windows PowerShell 5 mangles quotes in a jq filter passed to gh)
    $Remote = ((& $Gh api "repos/$Repo/releases/tags/v$Label" | ConvertFrom-Json).assets | Where-Object { $_.name -eq $Exe }).digest
    if ($Remote -eq "sha256:$($Info.sha256)") { Write-Host "- Release v$Label already has this exe" }
    else {
        Write-Host "- Adding the exe to release v$Label"
        & $Gh release upload "v$Label" "$Out\$Exe" --clobber --repo $Repo
    }
} elseif ($Beta) {
    Write-Host "- GitHub pre-release v$Label"
    & $Gh release create "v$Label" "$Out\$Exe" --repo $Repo --prerelease --target main --title "Hesper $Label (test version)" --notes $Info.notes
} else {
    Write-Host "- GitHub release v$Label"
    & $Gh release create "v$Label" "$Out\$Exe" --repo $Repo --target main --title "Hesper $Label" --notes $Info.notes
}
if ($LASTEXITCODE -ne 0) { throw "The GitHub release failed (gh auth login?)." }
git fetch -q --tags origin

# 3. Last: the feed (and, for a release, the model list), so apps only see an update once its
#    download exists. The site's Windows button turns on with latest-windows.json.
Copy-Item "$Out\$Feed" $Feed
if ($Beta) { git add $Feed } else { Copy-Item catalog\models.json models.json; git add $Feed models.json }
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git commit -qm "Hesper $Label for Windows" }
git push -q origin main
if ($LASTEXITCODE -ne 0) { throw "The exe is on the release, but the update file couldn't be pushed: git pull, then git push." }
if ($Beta) { Write-Host "OK: Published test version Hesper $Label for Windows - apps receiving test versions offer it within a day." }
else { Write-Host "OK: Released Hesper $Label for Windows - installed apps offer the update within a day." }
