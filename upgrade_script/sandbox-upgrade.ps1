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

function Get-EnvValue {
    param([string]$Key)

    $envFile = Join-Path $TargetDir ".env.clay"
    if (-not (Test-Path $envFile)) {
        return ""
    }
    foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
        if ($line -like "$Key=*") {
            $value = $line.Substring($Key.Length + 1).Trim()
            return $value.Trim('"')
        }
    }
    return ""
}

function Get-HealthUrl {
    $url = Get-EnvValue "CLAY_SANDBOX_URL"
    if (-not [string]::IsNullOrWhiteSpace($url)) {
        return ($url.TrimEnd("/") + "/health")
    }

    $addr = Get-EnvValue "LISTEN_ADDR"
    if ([string]::IsNullOrWhiteSpace($addr)) {
        $addr = "127.0.0.1:9000"
    } elseif ($addr.StartsWith(":")) {
        $addr = "127.0.0.1$addr"
    }
    if (-not ($addr.StartsWith("http://") -or $addr.StartsWith("https://"))) {
        $addr = "http://$addr"
    }
    return ($addr.TrimEnd("/") + "/health")
}

function Acquire-Lock {
    $existingPid = ""

    try {
        $script:LockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch {
        if (Test-Path $LockFile) {
            $existingPid = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if (-not [string]::IsNullOrWhiteSpace($existingPid) -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
            Add-Content -Path $UpdateLog -Value "upgrade already running"
            exit 0
        }
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        $script:LockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$PID")
    $script:LockStream.Write($bytes, 0, $bytes.Length)
    $script:LockStream.Flush()
}

function Release-Lock {
    if ($script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
    }
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-BinaryFile {
    param([string]$Path)

    try {
        & $Path help | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Start-Sandbox {
    $p = Start-Process -FilePath $TargetBin -ArgumentList "serve" -WorkingDirectory $TargetDir -WindowStyle Hidden -RedirectStandardOutput $RuntimeLog -RedirectStandardError $RuntimeLog -PassThru
    Set-Content -Path $PidFile -Value $p.Id
    return $p
}

function Wait-SandboxHealth {
    for ($i = 0; $i -lt 40; $i++) {
        try {
            Invoke-WebRequest -Uri (Get-HealthUrl) -TimeoutSec 5 | Out-Null
            return $true
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function Restore-Backup {
    $failedPid = ""
    if (Test-Path $PidFile) {
        $failedPid = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    try {
        & $TargetBin stop | Out-Null
    } catch {}
    [void](Wait-ProcessExit $failedPid)

    if (Test-Path $PidFile) {
        Remove-Item $PidFile -Force
    }
    if (-not (Test-Path $BackupFile)) {
        Add-Content -Path $UpdateLog -Value "rollback failed: backup missing"
        return $false
    }

    Copy-Item $BackupFile $TargetBin -Force
    [void](Start-Sandbox)
    if (Wait-SandboxHealth) {
        Add-Content -Path $UpdateLog -Value "rollback done"
        return $true
    }

    Add-Content -Path $UpdateLog -Value "rollback health check failed"
    return $false
}

$TargetBin = [System.IO.Path]::GetFullPath($TargetBin)
$TargetDir = Split-Path -Parent $TargetBin
$UpdateLog = Join-Path $TargetDir "sandbox-update.log"
$RuntimeLog = Join-Path $TargetDir "sandbox.log"
$PidFile = Join-Path $TargetDir "sandbox.pid"
$LockFile = Join-Path $TargetDir "sandbox-upgrade.lock"
$BinaryName = "clay-sandbox-windows-amd64.exe"
$DownloadUrl = "https://github.com/ClawWallet/Claw_Wallet_Bin/raw/refs/heads/main/bin/$BinaryName"
$TmpFile = "$TargetBin.download"
$BackupFile = "$TargetBin.bak.$CurrentVersion.$(Get-Date -Format 'yyyyMMddHHmmss')"

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
Add-Content -Path $UpdateLog -Value "upgrade start current=$CurrentVersion latest=$LatestVersion"
Acquire-Lock

try {
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

    if (-not (Test-BinaryFile $TmpFile)) {
        Remove-Item $TmpFile -Force
        Add-Content -Path $UpdateLog -Value "download verify failed"
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
    [void](Start-Sandbox)

    if (-not (Wait-SandboxHealth)) {
        Add-Content -Path $UpdateLog -Value "health check failed"
        [void](Restore-Backup)
        exit 1
    }

    Add-Content -Path $UpdateLog -Value "upgrade done"
} finally {
    Release-Lock
}
