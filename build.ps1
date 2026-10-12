# One-click build of FFmpeg + gpufx in Docker Desktop (Windows host).
#   .\build.ps1              win64
#   .\build.ps1 linux64
#   .\build.ps1 all
param([string]$Target = "win64")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$targets = if ($Target -eq "all") { @("linux64", "win64") } else { @($Target) }

git submodule update --init --depth 1 external/FFmpeg
if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }

foreach ($t in $targets) {
    if (-not (Test-Path "docker/$t.Dockerfile")) { throw "unknown target $t (linux64, win64, all)" }
    $image = "gpufx-build-$t"
    docker build -t $image -f "docker/$t.Dockerfile" docker
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
    New-Item -ItemType Directory -Force dist | Out-Null
    docker run --rm `
        -e TARGET=$t `
        -v "${PWD}:/src:ro" `
        -v "${PWD}/dist:/out" `
        -v gpufx-cargo-registry:/opt/cargo/registry `
        -v "gpufx-work-${t}:/build" `
        $image
    if ($LASTEXITCODE -ne 0) { throw "build for $t failed" }
}
