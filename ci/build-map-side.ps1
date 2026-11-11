$ErrorActionPreference = 'Stop'
$env:CARGO_TARGET_DIR = Join-Path $env:RUNNER_TEMP 'tpo-target'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
git diff --exit-code $env:FEATURE_REVISION -- tarkov-price-overlay
if ($LASTEXITCODE -ne 0) { throw 'Build source differs from the reviewed feature revision.' }

$sourceRoot = Join-Path $repoRoot 'tarkov-price-overlay'
$runtimeZip = Join-Path $env:RUNNER_TEMP 'official-runtime.zip'
$runtimeDir = Join-Path $env:RUNNER_TEMP 'official-runtime'
$runtimeUrl = 'https://github.com/pado8/tarkov-price-overlay-releases/releases/download/v1.3.1/Tarkov.Price.Overlay_1.3.1_portable.zip'
Invoke-WebRequest -Uri $runtimeUrl -OutFile $runtimeZip
$expected = '759B3286E21D24681FA9B9D6039FAF413057B19CFD672A8109F94BBBC0E40129'
if ((Get-FileHash -LiteralPath $runtimeZip -Algorithm SHA256).Hash -ne $expected) {
    throw 'Official OCR runtime checksum mismatch.'
}
Expand-Archive -LiteralPath $runtimeZip -DestinationPath $runtimeDir
$binDir = Join-Path $sourceRoot 'src-tauri/binaries'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $runtimeDir 'tarkov-server.exe') -Destination (Join-Path $binDir 'tarkov-server-x86_64-pc-windows-msvc.exe')
Copy-Item -LiteralPath (Join-Path $runtimeDir '_internal') -Destination $binDir -Recurse

rustup toolchain install stable --profile minimal
if ($LASTEXITCODE -ne 0) { throw 'Rust setup failed.' }
rustup default stable
if ($LASTEXITCODE -ne 0) { throw 'Rust toolchain selection failed.' }
Set-Location $sourceRoot
npm ci --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw 'JavaScript dependency installation failed.' }
npm run test:layout
if ($LASTEXITCODE -ne 0) { throw 'Map preference tests failed.' }

# Upstream intentionally ignores Cargo.lock. Resolve Rust packages to the same
# major/minor versions as its checked-in NPM lockfile, then restore Cargo.toml.
$lock = Get-Content -LiteralPath 'package-lock.json' -Raw | ConvertFrom-Json -AsHashtable
$manifestPath = (Resolve-Path -LiteralPath 'src-tauri/Cargo.toml').Path
$original = [IO.File]::ReadAllBytes($manifestPath)
$manifest = [Text.Encoding]::UTF8.GetString($original)
$packages = @{
    'tauri' = '@tauri-apps/api'
    'tauri-plugin-global-shortcut' = '@tauri-apps/plugin-global-shortcut'
    'tauri-plugin-process' = '@tauri-apps/plugin-process'
    'tauri-plugin-opener' = '@tauri-apps/plugin-opener'
    'tauri-plugin-dialog' = '@tauri-apps/plugin-dialog'
    'tauri-plugin-updater' = '@tauri-apps/plugin-updater'
    'tauri-plugin-notification' = '@tauri-apps/plugin-notification'
}
foreach ($crate in $packages.Keys) {
    $version = $lock.packages['node_modules/' + $packages[$crate]].version
    if ($version -notmatch '^(\d+)\.(\d+)\.') { throw "Unexpected locked package version: $crate" }
    $minor = $Matches[1] + '.' + $Matches[2]
    $pattern = '(?m)^' + [regex]::Escape($crate) + '\s*=\s*(\{\s*version\s*=\s*)?"2"'
    $manifest = [regex]::Replace($manifest, $pattern, ($crate + ' = ${1}"~' + $minor + '"'))
}
# Keep Tauri's internal crates on the matching 2.11.6 release family as well.
# Newer semver-compatible runtime crates changed APIs used by older tauri.
# Versions come from tauri-apps/tauri's tauri-v2.11.6 release manifests.
$manifest = $manifest.Replace('tauri-build = { version = "2"', 'tauri-build = { version = "=2.6.3"')
$internalPins = @'
tauri-macros = "=2.6.3"
tauri-codegen = "=2.6.3"
tauri-utils = "=2.9.3"
tauri-runtime = "=2.11.3"
tauri-runtime-wry = "=2.11.4"
tauri-plugin = "=2.6.3"

[dependencies]
'@
$manifest = $manifest.Replace('[dependencies]', $internalPins)
try {
    [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
    cargo update --manifest-path src-tauri/Cargo.toml
    if ($LASTEXITCODE -ne 0) { throw 'Could not align Rust dependency versions.' }
} finally {
    [IO.File]::WriteAllBytes($manifestPath, $original)
}
npm run tauri build -- --no-bundle
if ($LASTEXITCODE -ne 0) { throw 'Native Windows build failed.' }

$artifactDir = Join-Path $env:RUNNER_TEMP 'map-side-artifact'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$binary = Join-Path $env:CARGO_TARGET_DIR 'release/tarkov-price-overlay.exe'
Copy-Item -LiteralPath $binary -Destination (Join-Path $artifactDir 'Tarkov Price Overlay.exe')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination (Join-Path $artifactDir 'LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'src-tauri/Cargo.lock') -Destination (Join-Path $artifactDir 'Cargo.lock')
$metadata = [ordered]@{
    repository = $env:GITHUB_REPOSITORY
    featureRevision = $env:FEATURE_REVISION
    buildRevision = $env:GITHUB_SHA
    runtimeVersion = '1.3.1'
    binarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    change = 'Adds a persisted Settings > Map > Map side (Left/Right) preference.'
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifactDir 'BUILD-INFO.json') -Encoding utf8NoBOM
@'
Tarkov Price Overlay - ahastings map-side build

This modified build adds Settings > Map > Map side (Left / Right).
The original default remains Right; select Left for map-left / prices-right.
Portrait monitors keep the card above the map.

Source fork: https://github.com/ahastings/tarkov-price-overlay
Original project and copyright: pado / https://github.com/pado8/tarkov-price-overlay
License: MIT (see LICENSE.txt).

Use this executable alongside the unchanged official v1.3.1 tarkov-server.exe
and _internal directory. BUILD-INFO.json identifies the exact source and hash.
'@ | Set-Content -LiteralPath (Join-Path $artifactDir 'LOCAL-BUILD.txt') -Encoding utf8NoBOM
