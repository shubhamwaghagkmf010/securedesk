<#
.SYNOPSIS
  Builds the SecureDesk Windows clients (session client x64/x86 and the agent installer) and puts them where the Docker image build expects them.

.PARAMETER ServerUrl
  Optional. URL of YOUR server (for example https://desk.example.com). It is built into the installer and the session client,
  so users do not have to type it. Leave empty to build generic clients that ask for the server URL (upstream behaviour).

.PARAMETER Version
  File/product version stamped on the binaries.

.PARAMETER OutDir
  Output folder. Default: docker\overlay\Content (picked up by docker\Dockerfile).

.EXAMPLE
  .\build\Build-WindowsClients.ps1
  .\build\Build-WindowsClients.ps1 -ServerUrl https://desk.example.com

Requirements: Windows, .NET SDK 6 or newer (the build restores the .NET 6 targeting packs from nuget.org).
#>
param(
    [string]$ServerUrl = "",
    [string]$Version = "2022.08.02.0428",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root "docker\overlay\Content" }

if ($ServerUrl -and ($ServerUrl -notmatch '^https?://[^\s"]+$')) {
    throw "ServerUrl must look like https://host or http://host:port (no spaces or quotes)."
}
$ServerUrl = $ServerUrl.TrimEnd('/')

$embedded = Join-Path $root "Shared\Models\EmbeddedServer.cs"
$original = [IO.File]::ReadAllText($embedded)
$nuget = "https://api.nuget.org/v3/index.json"

try {
    # 1) build the server URL into the clients (file is restored in the finally block)
    $patched = [regex]::Replace($original, 'public const string Url = "[^"]*";', 'public const string Url = "' + $ServerUrl + '";')
    [IO.File]::WriteAllText($embedded, $patched)
    Write-Host "Server URL built into the clients: '$ServerUrl' (empty = user is asked)"

    # 2) session client, 64 and 32 bit, single self-contained exe
    foreach ($arch in "x64", "x86") {
        $dest = Join-Path $OutDir "Win-$arch"
        New-Item -ItemType Directory -Force $dest | Out-Null
        Write-Host "Publishing session client $arch ..."
        & dotnet publish (Join-Path $root "Desktop.Win\Desktop.Win.csproj") -c Release "-p:PublishProfile=desktop-win-$arch" "-p:PublishDir=$dest" "-p:Version=$Version" "-p:FileVersion=$Version" "-p:RestoreSources=$nuget" -nologo -v minimal
        if ($LASTEXITCODE -ne 0) { throw "session client $arch build failed" }
        Get-ChildItem $dest -File | Where-Object { $_.Name -ne "Remotely_Desktop.exe" } | ForEach-Object { [IO.File]::Delete($_.FullName) }
    }

    # 3) agent installer (.NET Framework 4.8, needs Administrator when run)
    Write-Host "Building installer ..."
    & dotnet build (Join-Path $root "Agent.Installer.Win\SecureDesk.Installer.csproj") -c Release --no-incremental "-p:Version=$Version" "-p:FileVersion=$Version" "-p:RestoreSources=$nuget" -nologo -v minimal
    if ($LASTEXITCODE -ne 0) { throw "installer build failed" }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    Copy-Item (Join-Path $root "Agent.Installer.Win\bin\Release\net48\Remotely_Installer.exe") (Join-Path $OutDir "Remotely_Installer.exe") -Force

    Write-Host ""
    Write-Host "Done. Output in $OutDir"
    Get-ChildItem $OutDir -Recurse -File | ForEach-Object { "{0,-45} {1,12:N0} bytes" -f $_.FullName.Substring($OutDir.Length + 1), $_.Length }
}
finally {
    [IO.File]::WriteAllText($embedded, $original)
}
