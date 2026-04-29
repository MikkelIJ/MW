# Windows installer for MW (Mikkel's Workspace).
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/MikkelIJ/MW/main/install.ps1 | iex
#
# Env overrides:
#   $env:MW_VERSION = 'v0.2.0'           # specific tag (default: latest)
#   $env:MW_DEST    = "$env:LOCALAPPDATA\MW"

$ErrorActionPreference = 'Stop'
$repo = 'MikkelIJ/MW'
$dest = if ($env:MW_DEST) { $env:MW_DEST } else { Join-Path $env:LOCALAPPDATA 'MW' }

if ($env:MW_VERSION) {
    $tag = $env:MW_VERSION
} else {
    Write-Host '-> Resolving latest release...'
    $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}
Write-Host "-> Installing MW $tag to $dest"

$zip = "https://github.com/$repo/releases/download/$tag/MW-windows-x64.zip"
$sha = "$zip.sha256"
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "mw-$([guid]::NewGuid().ToString('N'))")
try {
    $zipPath = Join-Path $tmp 'MW.zip'
    Invoke-WebRequest -Uri $zip -OutFile $zipPath -UseBasicParsing
    try {
        $expected = (Invoke-WebRequest -Uri $sha -UseBasicParsing).Content.Trim().Split()[0]
        $actual   = (Get-FileHash $zipPath -Algorithm SHA256).Hash
        if ($expected -ne $actual) { throw "checksum mismatch ($actual vs $expected)" }
        Write-Host '-> Checksum OK'
    } catch {
        Write-Warning "Skipping checksum verification: $_"
    }

    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $dest -Force

    # Optional: pin a Start Menu shortcut.
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $shortcut  = Join-Path $startMenu 'MW.lnk'
    $exe       = Join-Path $dest 'MW.exe'
    if (Test-Path $exe) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($shortcut)
        $lnk.TargetPath = $exe
        $lnk.Save()
    }

    Write-Host "[OK] Installed MW $tag to $dest"
    Write-Host "    Launch with: $exe"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
