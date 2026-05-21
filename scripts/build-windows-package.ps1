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
  $env:npm_config_python = (Get-Command python.exe).Source

  npm init -y | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "npm init failed with exit code $LASTEXITCODE"
  }

  npm install "code-server@$Version" --omit=dev --no-audit --no-fund --ignore-scripts
  if ($LASTEXITCODE -ne 0) {
    throw "npm install code-server@$Version failed with exit code $LASTEXITCODE"
  }

  $VsCodeDir = Join-Path $Bundle "node_modules\code-server\lib\vscode"
  Push-Location $VsCodeDir
  try {
    npm install --omit=dev --no-audit --no-fund --ignore-scripts
    if ($LASTEXITCODE -ne 0) {
      throw "npm install VS Code runtime dependencies failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }

  $SpdlogIndex = Join-Path $VsCodeDir "node_modules\@vscode\spdlog\index.js"
  @'
exports.version = 'js-fallback';
exports.setLevel = function () {};
exports.setFlushOn = function () {};
class Logger {
  constructor() {}
  trace() {}
  debug() {}
  info() {}
  warn() {}
  error() {}
  critical() {}
  flush() {}
  drop() {}
}
exports.Logger = Logger;
async function createLogger() {
  return new Logger();
}
exports.createRotatingLogger = createLogger;
exports.createAsyncRotatingLogger = createLogger;
'@ | Set-Content -Path $SpdlogIndex -Encoding ASCII

  $DeviceStorage = Join-Path $VsCodeDir "node_modules\@vscode\deviceid\dist\storage.js"
  @'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setDeviceId = exports.getDeviceId = void 0;
async function getDeviceId() {
  return undefined;
}
exports.getDeviceId = getDeviceId;
async function setDeviceId(_deviceId) {}
exports.setDeviceId = setDeviceId;
'@ | Set-Content -Path $DeviceStorage -Encoding ASCII

  $WinRegistry = Join-Path $VsCodeDir "node_modules\@vscode\windows-registry\dist\index.js"
  @'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.GetDWORDRegKey = exports.GetStringRegKey = void 0;
function GetStringRegKey(_hive, _path, _name) {
  return undefined;
}
exports.GetStringRegKey = GetStringRegKey;
function GetDWORDRegKey(_hive, _path, _name) {
  return undefined;
}
exports.GetDWORDRegKey = GetDWORDRegKey;
'@ | Set-Content -Path $WinRegistry -Encoding ASCII

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
  $Proc = Start-Process `
    -FilePath (Join-Path $Bundle "start-code-server.cmd") `
    -ArgumentList @("--bind-addr", "127.0.0.1:$Port", "--auth", "none", "--disable-telemetry") `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $Stdout `
    -RedirectStandardError $Stderr

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
      if (Test-Path $Stdout) {
        Write-Host "---- code-server stdout ----"
        Get-Content $Stdout -ErrorAction SilentlyContinue
      }
      if (Test-Path $Stderr) {
        Write-Host "---- code-server stderr ----"
        Get-Content $Stderr -ErrorAction SilentlyContinue
      }
      throw "Smoke test failed: expected HTTP 200 from 127.0.0.1:$Port, got $Status"
    }

    "HTTP $Status from http://127.0.0.1:$Port" | Tee-Object -FilePath (Join-Path $Logs "http-smoke.txt")
  } finally {
    if (-not $Proc.HasExited) {
      Stop-Process -Id $Proc.Id -Force
      Wait-Process -Id $Proc.Id -Timeout 15 -ErrorAction SilentlyContinue
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
