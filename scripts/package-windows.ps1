# Builds the `aso` command for Windows as a self-contained folder and zip: aso.exe plus exactly the Swift runtime
# DLLs it loads (found by walking import tables), so it runs on machines without a Swift toolchain.
#
#   powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1     -> dist\aso-windows-x86_64.zip
#
# With -Window it also publishes the Windows window (desktop/, self-contained .NET) with that aso folder next to
# it, where the window looks first, so one folder runs without .NET or Swift installed:
#
#   ... package-windows.ps1 -Window                                          -> dist\aso-workbench-windows-x86_64.zip
#
# The Swift runtime cannot be linked statically on Windows yet (FoundationNetworking needs a static libcurl the
# toolchain does not ship), so the DLLs travel next to the executable, which Windows searches first.
[CmdletBinding()]
param([string]$Output = 'dist', [switch]$Window)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$version = (Get-Content VERSION -Raw).Trim()

swift build -c release --product aso
if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
$bin = (swift build -c release --show-bin-path).Trim()
$exe = Join-Path $bin 'aso.exe'

# The runtime folder is the one on PATH that holds swiftCore.dll.
$runtime = $env:Path -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
if (-not $runtime) { throw 'No Swift runtime (swiftCore.dll) on PATH' }
$readobj = Get-Command llvm-readobj -ErrorAction SilentlyContinue
if (-not $readobj) { throw 'llvm-readobj (part of the Swift toolchain) is not on PATH' }

# Breadth-first over import tables; only DLLs from the Swift runtime folder are shipped, system DLLs stay with Windows.
function Get-Imports([string]$file) {
    & $readobj.Source --coff-imports $file | Select-String -Pattern '^\s*Name:\s*(\S+\.dll)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
}
$shipped = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue($exe)
while ($queue.Count -gt 0) {
    foreach ($name in Get-Imports $queue.Dequeue()) {
        $candidate = Join-Path $runtime $name
        if ((Test-Path $candidate) -and $shipped.Add($name)) { $queue.Enqueue($candidate) }
    }
}

$stage = Join-Path $Output 'aso-windows-x86_64'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe $stage
foreach ($name in $shipped) { Copy-Item (Join-Path $runtime $name) $stage }
Copy-Item LICENSE $stage

# Prove the folder is self-contained: run it with nothing but Windows on PATH.
$savedPath = $env:Path
try {
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $reported = & (Join-Path $stage 'aso.exe') --version
    if ($LASTEXITCODE -ne 0 -or $reported -ne "aso $version") { throw "Packaged aso.exe failed to run (exit $LASTEXITCODE): $reported" }
} finally {
    $env:Path = $savedPath
}

function Write-Zip([string]$folder, [string]$name) {
    $zip = Join-Path $Output "$name.zip"
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name.zip" | Set-Content -Encoding ascii (Join-Path $Output "$name.sha256")
    Write-Host "-> $zip ($([int]((Get-Item $zip).Length / 1MB)) MB)"
}

Write-Zip $stage 'aso-windows-x86_64'
Write-Host "  $reported, $($shipped.Count) runtime DLLs"

if ($Window) {
    # Self-contained: the .NET runtime travels with the window. No trimming: Avalonia's XAML relies on reflection.
    $app = Join-Path $Output 'aso-workbench-windows-x86_64'
    Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    dotnet publish desktop\src\AsoDesktop\AsoDesktop.csproj --configuration Release --runtime win-x64 --self-contained true `
        -p:DebugType=none --output $app
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
    # aso and its runtime go next to the window; a name both sides ship would make one overwrite the other.
    foreach ($file in Get-ChildItem $stage -File) {
        if (Test-Path (Join-Path $app $file.Name)) { throw "$($file.Name) is shipped by both the window and aso" }
        Copy-Item $file.FullName $app
    }
    if (-not (Test-Path (Join-Path $app 'ASOWorkbench.exe'))) { throw 'The published window has no ASOWorkbench.exe' }
    Write-Zip $app 'aso-workbench-windows-x86_64'
}
