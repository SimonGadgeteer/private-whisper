<#
.SYNOPSIS
  Builds and packages Private Whisper for Windows.

  1. dotnet publish (self-contained single-file win-x64) -> dist\app
  2. Downloads the PINNED official sidecar binaries into dist\app\runtime\
       - llama.cpp  llama-server.exe  (Vulkan build: runs on Intel/AMD/NVIDIA
         iGPUs via the standard driver; falls back to CPU when no Vulkan
         device is present — the release zips bundle the CPU backend DLLs)
       - whisper.cpp whisper-server.exe (CPU build; whisper.cpp publishes no
         Vulkan Windows asset — see $WhisperZipUrl notes)
     NOTE: the two zips ship DIFFERENT ggml*.dll versions, so each server gets
     its own subdirectory (runtime\whisper\, runtime\llama\). The app probes
     runtime\<name>\<server>.exe first, then runtime\<server>.exe.
  3. Assembles the portable folder (adds portable.marker) and zips it.
  4. Optionally compiles the per-user Inno Setup installer (-Installer).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\package.ps1
  powershell -ExecutionPolicy Bypass -File scripts\package.ps1 -Installer
#>
param(
    [switch]$Installer,
    [switch]$SkipPublish
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Pinned sidecar releases (verified 2026-08-17). Bump deliberately; re-run the
# eval gate (evals/) after any change.
# ---------------------------------------------------------------------------
$LlamaTag       = "b10472"
$LlamaZipUrl    = "https://github.com/ggml-org/llama.cpp/releases/download/b10472/llama-b10472-bin-win-vulkan-x64.zip"
# CPU-only alternative if Vulkan is unavailable/undesired on the target machine:
$LlamaCpuZipUrl = "https://github.com/ggml-org/llama.cpp/releases/download/b10472/llama-b10472-bin-win-cpu-x64.zip"

$WhisperTag     = "v1.9.2"
# whisper.cpp v1.9.2 Windows assets: whisper-bin-x64.zip (CPU),
# whisper-blas-bin-x64.zip (OpenBLAS), whisper-cublas-*-bin-x64.zip (NVIDIA).
# No Vulkan asset is published; CPU is the safe default for no-admin notebooks.
$WhisperZipUrl  = "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-x64.zip"

$AppVersion = "0.2.0"

# ---------------------------------------------------------------------------
$WindowsDir = Split-Path -Parent $PSScriptRoot   # ...\windows
$DistDir    = Join-Path $WindowsDir "dist"
$AppDir     = Join-Path $DistDir "app"
$BuildDir   = Join-Path $DistDir "build"
$ProjectRel = "src\PrivateWhisper\PrivateWhisper.csproj"

New-Item -ItemType Directory -Force -Path $DistDir, $BuildDir | Out-Null

# 1. Publish -----------------------------------------------------------------
if (-not $SkipPublish) {
    Write-Host "== dotnet publish (self-contained single-file win-x64) =="
    if (Test-Path $AppDir) { Remove-Item -Recurse -Force $AppDir }
    dotnet publish (Join-Path $WindowsDir $ProjectRel) `
        -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $AppDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
}

# 2. Sidecar binaries --------------------------------------------------------
function Get-Zip([string]$Url, [string]$Destination) {
    if (-not (Test-Path $Destination)) {
        Write-Host "Downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } else {
        Write-Host "Cached: $Destination"
    }
}

Write-Host "== Sidecar binaries =="
$LlamaZip   = Join-Path $BuildDir "llama-$LlamaTag-win-vulkan-x64.zip"
$WhisperZip = Join-Path $BuildDir "whisper-$WhisperTag-win-x64.zip"
Get-Zip $LlamaZipUrl   $LlamaZip
Get-Zip $WhisperZipUrl $WhisperZip

$LlamaExtract   = Join-Path $BuildDir "llama"
$WhisperExtract = Join-Path $BuildDir "whisper"
foreach ($dir in @($LlamaExtract, $WhisperExtract)) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}
Expand-Archive -Path $LlamaZip   -DestinationPath $LlamaExtract
Expand-Archive -Path $WhisperZip -DestinationPath $WhisperExtract

# Each sidecar gets its own directory: the zips ship different ggml*.dll builds.
$RuntimeLlama   = Join-Path $AppDir "runtime\llama"
$RuntimeWhisper = Join-Path $AppDir "runtime\whisper"
New-Item -ItemType Directory -Force -Path $RuntimeLlama, $RuntimeWhisper | Out-Null

# llama.cpp zips place binaries either at the root or under build\bin.
$llamaServer = Get-ChildItem -Path $LlamaExtract -Recurse -Filter "llama-server.exe" | Select-Object -First 1
if (-not $llamaServer) { throw "llama-server.exe not found in $LlamaZip" }
Copy-Item $llamaServer.FullName $RuntimeLlama
Get-ChildItem -Path $llamaServer.DirectoryName -Filter "*.dll" | Copy-Item -Destination $RuntimeLlama

# whisper.cpp zips place binaries under Release\.
$whisperServer = Get-ChildItem -Path $WhisperExtract -Recurse -Filter "whisper-server.exe" | Select-Object -First 1
if (-not $whisperServer) { throw "whisper-server.exe not found in $WhisperZip" }
Copy-Item $whisperServer.FullName $RuntimeWhisper
Get-ChildItem -Path $whisperServer.DirectoryName -Filter "*.dll" | Copy-Item -Destination $RuntimeWhisper

# 3. Portable folder + zip ---------------------------------------------------
Write-Host "== Portable package =="
$PortableDir = Join-Path $DistDir "PrivateWhisper-portable"
if (Test-Path $PortableDir) { Remove-Item -Recurse -Force $PortableDir }
Copy-Item -Recurse $AppDir $PortableDir
# The marker switches the app to portable mode: config/models/stats/log stay
# in this folder. Delete folder = fully uninstalled.
Set-Content -Path (Join-Path $PortableDir "portable.marker") -Value "portable"

$PortableZip = Join-Path $DistDir "PrivateWhisper-windows-$AppVersion-portable.zip"
if (Test-Path $PortableZip) { Remove-Item -Force $PortableZip }
Compress-Archive -Path "$PortableDir\*" -DestinationPath $PortableZip
$hash = (Get-FileHash -Algorithm SHA256 $PortableZip).Hash
Write-Host "Portable zip: $PortableZip"
Write-Host "SHA-256:      $hash"

# 4. Installer (optional) ----------------------------------------------------
if ($Installer) {
    Write-Host "== Inno Setup installer =="
    $iscc = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "ISCC.exe"
    ) | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $iscc) { throw "ISCC.exe (Inno Setup 6) not found — install it or add it to PATH" }
    & $iscc (Join-Path $WindowsDir "installer\setup.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compile failed" }
    Write-Host "Installer written to $DistDir"
}

Write-Host "Done."
