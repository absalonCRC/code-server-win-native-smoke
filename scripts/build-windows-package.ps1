$ErrorActionPreference = "Stop"

$Version = $env:CODE_SERVER_VERSION
if (-not $Version) {
  $Version = "4.117.0"
}

$Port = 18082
$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$Work = Join-Path $RepoRoot "work"
$BundleName = "code-server-windows-native-$Version"
$Bundle = Join-Path $Work $BundleName
$Logs = Join-Path $Bundle "smoke-logs"

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Bundle | Out-Null
New-Item -ItemType Directory -Force $Logs | Out-Null

Push-Location $Bundle
try {
  npm init -y | Out-Null
  npm install "code-server@$Version" --omit=dev --no-audit --no-fund

  $NodePath = (Get-Command node.exe).Source
  Copy-Item $NodePath (Join-Path $Bundle "node.exe") -Force

  @"
@echo off
setlocal
set ROOT=%~dp0
set PATH=%ROOT%;%PATH%
"%ROOT%node.exe" "%ROOT%node_modules\code-server\out\node\entry.js" %*
"@ | Set-Content -Path (Join-Path $Bundle "start-code-server.cmd") -Encoding ASCII

  $VersionOutput = & (Join-Path $Bundle "start-code-server.cmd") --version
  $VersionOutput | Tee-Object -FilePath (Join-Path $Logs "version.txt")

  $Stdout = Join-Path $Logs "stdout.txt"
  $Stderr = Join-Path $Logs "stderr.txt"
  $Args = "/c `"`"$Bundle\start-code-server.cmd`" --bind-addr 127.0.0.1:$Port --auth none --disable-telemetry`""
  $Proc = Start-Process -FilePath "cmd.exe" -ArgumentList $Args -PassThru -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr

  try {
    $Status = $null
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 1
      try {
        $Response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port" -UseBasicParsing -TimeoutSec 2
        $Status = $Response.StatusCode
        if ($Status -eq 200) {
          break
        }
      } catch {
        if ($Proc.HasExited) {
          throw "code-server exited during smoke test with code $($Proc.ExitCode)"
        }
      }
    }

    if ($Status -ne 200) {
      throw "Smoke test failed: expected HTTP 200 from 127.0.0.1:$Port, got $Status"
    }

    "HTTP $Status from http://127.0.0.1:$Port" | Tee-Object -FilePath (Join-Path $Logs "http-smoke.txt")
  } finally {
    if (-not $Proc.HasExited) {
      Stop-Process -Id $Proc.Id -Force
    }
  }
} finally {
  Pop-Location
}

$Zip = Join-Path $Work "$BundleName.zip"
Compress-Archive -Path (Join-Path $Bundle "*") -DestinationPath $Zip -Force

$Hash = Get-FileHash -Algorithm SHA256 $Zip
"$($Hash.Hash)  $BundleName.zip" | Set-Content -Path (Join-Path $Work "SHA256SUMS.txt") -Encoding ASCII

Write-Host "Built $Zip"
Write-Host "SHA256 $($Hash.Hash)"
