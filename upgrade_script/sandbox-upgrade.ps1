param(
    [string]$CurrentVersion = "unknown",
    [string]$LatestVersion = "latest",
    [Parameter(Mandatory = $true)]
    [string]$TargetBin,
    [string]$OldPid = ""
)

$ErrorActionPreference = "Stop"

function Wait-ProcessExit {
    param([string]$PidText)

    if ([string]::IsNullOrWhiteSpace($PidText)) {
        return $true
    }
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Get-Process -Id $PidText -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

$TargetBin = [System.IO.Path]::GetFullPath($TargetBin)
$TargetDir = Split-Path -Parent $TargetBin
$UpdateLog = Join-Path $TargetDir "sandbox-update.log"
$RuntimeLog = Join-Path $TargetDir "sandbox.log"
$PidFile = Join-Path $TargetDir "sandbox.pid"
$BinaryName = "clay-sandbox-windows-amd64.exe"
$DownloadUrl = "https://github.com/ClawWallet/Claw_Wallet_Bin/raw/refs/heads/main/bin/$BinaryName"
$TmpFile = "$TargetBin.download"
$BackupFile = "$TargetBin.bak.$CurrentVersion.$(Get-Date -Format 'yyyyMMddHHmmss')"

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
Add-Content -Path $UpdateLog -Value "upgrade start current=$CurrentVersion latest=$LatestVersion"

if (Test-Path $TmpFile) {
    Remove-Item $TmpFile -Force
}

try {
    Invoke-WebRequest -Uri $DownloadUrl -Method Head -TimeoutSec 20 | Out-Null
} catch {
    Add-Content -Path $UpdateLog -Value "network check failed"
    exit 1
}

try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TmpFile -TimeoutSec 600
} catch {
    if (Test-Path $TmpFile) {
        Remove-Item $TmpFile -Force
    }
    Add-Content -Path $UpdateLog -Value "download failed"
    exit 1
}

if (-not (Test-Path $TmpFile) -or (Get-Item $TmpFile).Length -le 0) {
    if (Test-Path $TmpFile) {
        Remove-Item $TmpFile -Force
    }
    Add-Content -Path $UpdateLog -Value "download empty"
    exit 1
}

try {
    & $TargetBin stop | Out-Null
} catch {}

if (-not (Wait-ProcessExit $OldPid)) {
    Remove-Item $TmpFile -Force
    Add-Content -Path $UpdateLog -Value "stop timeout"
    exit 1
}

if (Test-Path $PidFile) {
    Remove-Item $PidFile -Force
}

if (Test-Path $TargetBin) {
    Copy-Item $TargetBin $BackupFile -Force
}

Move-Item $TmpFile $TargetBin -Force
$p = Start-Process -FilePath $TargetBin -ArgumentList "serve" -WorkingDirectory $TargetDir -WindowStyle Hidden -RedirectStandardOutput $RuntimeLog -RedirectStandardError $RuntimeLog -PassThru
Set-Content -Path $PidFile -Value $p.Id

Add-Content -Path $UpdateLog -Value "upgrade done"
