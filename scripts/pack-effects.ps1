# Packs effect folders into .zip packages only: no FFmpeg, no Docker.
# Every package is validated first (manifest, rules, file references) by `gpufx pack`.
#   .\scripts\pack-effects.ps1                          all of examples\effects -> dist\effects\<group>\<name>.zip
#   .\scripts\pack-effects.ps1 -Out out my-fx other-fx   chosen folders -> out\
#   .\scripts\pack-effects.ps1 -Check                   also compile every shader on the GPU
param(
    [string]$Out = "",
    [switch]$Check,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Dirs
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root "dist/effects" }
if (-not $Dirs) { $Dirs = Get-ChildItem -Directory (Join-Path $root "examples/effects") | Get-ChildItem -Directory | ForEach-Object FullName }

cargo build --release --quiet --manifest-path (Join-Path $root "Cargo.toml") -p gpufx-cli
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
$gpufx = Join-Path $root "target/release/gpufx"
New-Item -ItemType Directory -Force $Out | Out-Null

foreach ($dir in $Dirs) {
    if (-not (Test-Path (Join-Path $dir "manifest.json"))) { throw "${dir}: no manifest.json" }
    if ($Check) {
        & $gpufx check $dir
        if ($LASTEXITCODE -ne 0) { throw "check failed: $dir" }
    }
    # Effects of examples\effects keep their group folder (out\<group>\<name>.zip);
    # other folders are packed flat (out\<name>.zip).
    $full = (Resolve-Path $dir).Path.TrimEnd('\', '/')
    $examples = (Resolve-Path (Join-Path $root "examples/effects")).Path
    $rel = Split-Path -Leaf $full
    if ($full.StartsWith($examples + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($examples.Length + 1)
    }
    $zip = Join-Path $Out ($rel + ".zip")
    New-Item -ItemType Directory -Force (Split-Path -Parent $zip) | Out-Null
    & $gpufx pack $full $zip
    if ($LASTEXITCODE -ne 0) { throw "pack failed: $dir" }
}
