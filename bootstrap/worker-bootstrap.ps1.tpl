$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Fix PowerShell 5.1 HTTP issues: disable Expect: 100-continue and enable modern TLS
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$WorkerBootstrapCode = __WORKER_BOOTSTRAP_CODE__
$PlatformUrl = __PLATFORM_URL__
$WorkerName = __WORKER_NAME__
$Runtime = __RUNTIME__
$CodexHomeDir = __CODEX_HOME_DIR__
$CodexModel = __CODEX_MODEL__
$CodexModelReasoningEffort = __CODEX_MODEL_REASONING_EFFORT__
$CodexSandboxMode = __CODEX_SANDBOX_MODE__
$CodexApprovalPolicy = __CODEX_APPROVAL_POLICY__
$MaxConcurrent = "__MAX_CONCURRENT__"
$MaxBudgetUsd = "__MAX_BUDGET_USD__"
$MaxTurns = "__MAX_TURNS__"
$ArchiveUrl = __WORKER_ARCHIVE_URL__
$WorkerVersion = __WORKER_VERSION__
$HttpProxy = @($env:HTTP_PROXY, $env:http_proxy) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
$HttpsProxy = @($env:HTTPS_PROXY, $env:https_proxy) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
$AllProxy = @($env:ALL_PROXY, $env:all_proxy) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
$NoProxy = @($env:NO_PROXY, $env:no_proxy) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
$PlatformHost = ""
try {
    $PlatformHost = ([Uri]$PlatformUrl).Host
} catch {
    $PlatformHost = ""
}

function Write-Log {
    param([string]$Message, [string]$MessageEn = "")
    if ($MessageEn) {
        Write-Host "  ● [AIMA] $Message / $MessageEn" -ForegroundColor Cyan
    } else {
        Write-Host "  ● [AIMA] $Message" -ForegroundColor Cyan
    }
}

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-PathIfPresent {
    param([string]$PathEntry)
    if ((Test-Path $PathEntry) -and -not (($env:Path -split ';') -contains $PathEntry)) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Resolve-HomePath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }
    if ($PathValue -eq "~") {
        return $HOME
    }
    if ($PathValue.StartsWith("~/") -or $PathValue.StartsWith("~\\")) {
        return Join-Path $HOME $PathValue.Substring(2)
    }
    return $PathValue
}

function Refresh-CommonPath {
    Add-PathIfPresent "$env:ProgramFiles\nodejs"
    Add-PathIfPresent "$env:AppData\npm"
    Add-PathIfPresent "$env:LocalAppData\Microsoft\WindowsApps"
    Add-PathIfPresent "$env:LocalAppData\Programs\Python\Python311"
    Add-PathIfPresent "$env:LocalAppData\Programs\Python\Python311\Scripts"
    Add-PathIfPresent "$env:LocalAppData\Programs\Python\Python312"
    Add-PathIfPresent "$env:LocalAppData\Programs\Python\Python312\Scripts"
}

function Get-PythonExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (Test-Command "python") {
        $candidates.Add((Get-Command python).Source)
    }

    if (Test-Command "py") {
        foreach ($selector in @("-3.11", "-3")) {
            try {
                $resolved = (& py $selector -c "import sys; print(sys.executable)" 2>$null).Trim()
                if ($resolved) {
                    $candidates.Add($resolved)
                }
            } catch {
            }
        }
    }

    foreach ($candidate in @(
        "$env:LocalAppData\Programs\Python\Python311\python.exe",
        "$env:LocalAppData\Programs\Python\Python312\python.exe"
    )) {
        if (Test-Path $candidate) {
            $candidates.Add($candidate)
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            & $candidate -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $candidate
            }
        } catch {
        }
    }

    return $null
}

function Ensure-Python {
    $pythonExe = Get-PythonExecutable
    if ($pythonExe) {
        return $pythonExe
    }

    if (-not (Test-Command "winget")) {
        throw "Python 3.11+ is required and winget is unavailable for automatic installation."
    }

    Write-Log "正在安装 Python 3.11" "Installing Python 3.11"
    & winget install --id Python.Python.3.11 -e --accept-package-agreements --accept-source-agreements --disable-interactivity
    Refresh-CommonPath
    $pythonExe = Get-PythonExecutable
    if (-not $pythonExe) {
        throw "Python 3.11+ is still unavailable after installation / 安装后 Python 3.11+ 仍不可用"
    }
    return $pythonExe
}

function Ensure-Node {
    Refresh-CommonPath
    if ((Test-Command "node") -and (Test-Command "npm")) {
        return
    }

    if (-not (Test-Command "winget")) {
        throw "Node.js is required and winget is unavailable for automatic installation."
    }

    Write-Log "正在安装 Node.js LTS" "Installing Node.js LTS"
    & winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements --disable-interactivity
    Refresh-CommonPath
    if (-not (Test-Command "node") -or -not (Test-Command "npm")) {
        throw "Node.js/npm is still unavailable after installation / 安装后 Node.js/npm 仍不可用"
    }
}

function Ensure-Claude {
    if (-not (Test-Command "claude")) {
        throw "claude CLI is not installed / 未安装 claude CLI"
    }

    $statusRaw = & claude auth status
    $status = $statusRaw | ConvertFrom-Json
    if (-not $status.loggedIn) {
        throw "claude CLI is not logged in / claude CLI 未登录"
    }
}

function Ensure-Codex {
    if (-not (Test-Command "codex")) {
        Write-Log "正在安装 Codex CLI" "Installing Codex CLI"
        & npm install -g @openai/codex
        Refresh-CommonPath
    }

    if (-not (Test-Command "codex")) {
        throw "codex CLI is not installed / 未安装 codex CLI"
    }

    if (-not [string]::IsNullOrWhiteSpace($CodexHomeDir)) {
        $script:CodexHomeDir = Resolve-HomePath $CodexHomeDir
        New-Item -ItemType Directory -Path $CodexHomeDir -Force | Out-Null
        $env:CODEX_HOME = $CodexHomeDir
    }

    & codex login status | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "codex CLI is not logged in / codex CLI 未登录"
    }
}

function New-QuotedPowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-QuotedCmdArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '""') + '"'
}

function Add-LauncherEnvLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Name,
        [string]$Value
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $Lines.Add('set "' + $Name + '=' + ($Value -replace '"', '""') + '"')
    }
}

function Merge-NoProxyValue {
    param(
        [string]$CurrentValue,
        [string]$HostValue
    )
    if ([string]::IsNullOrWhiteSpace($HostValue)) {
        return $CurrentValue
    }

    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($item in ($CurrentValue -split ',')) {
        $trimmed = $item.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $entries.Contains($trimmed)) {
            $entries.Add($trimmed)
        }
    }
    if (-not $entries.Contains($HostValue)) {
        $entries.Add($HostValue)
    }
    return ($entries -join ',')
}

$NoProxy = Merge-NoProxyValue -CurrentValue $NoProxy -HostValue $PlatformHost

$PythonExe = Ensure-Python
Ensure-Node
if ($Runtime -eq "codex") {
    Ensure-Codex
} else {
    Ensure-Claude
}

$WorkRoot = if ($env:AIMA_WORKER_HOME) { $env:AIMA_WORKER_HOME } else { Join-Path $HOME ".aima-worker" }
$ArchivePath = Join-Path $WorkRoot "aima-service-new.zip"
$ExtractRoot = Join-Path $WorkRoot "extract"
$SrcDir = Join-Path $WorkRoot "src"
$VenvDir = Join-Path $WorkRoot "venv"
$McpServerPath = Join-Path $SrcDir "apps\mcp-server\dist\index.js"

New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
Remove-Item -Recurse -Force $ExtractRoot, $SrcDir, $VenvDir -ErrorAction SilentlyContinue

Write-Log "正在从 $ArchiveUrl 下载 Worker 包" "Downloading worker bundle from $ArchiveUrl"
Invoke-WebRequest -UseBasicParsing $ArchiveUrl -OutFile $ArchivePath
Expand-Archive -Path $ArchivePath -DestinationPath $ExtractRoot -Force
$SourceRoot = $ExtractRoot
if (-not (Test-Path (Join-Path $SourceRoot "apps\worker"))) {
    $ExpandedDir = Get-ChildItem -Path $ExtractRoot -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName "apps\worker")
    } | Select-Object -First 1
    if (-not $ExpandedDir) {
        throw "Downloaded archive did not contain an apps/worker source tree / 下载的压缩包不包含 apps/worker 源码"
    }
    $SourceRoot = $ExpandedDir.FullName
}
New-Item -ItemType Directory -Path $SrcDir -Force | Out-Null
Get-ChildItem -Path $SourceRoot -Force | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $SrcDir -Recurse -Force
}

Write-Log "正在创建 Python 虚拟环境" "Creating Python virtualenv"
& $PythonExe -m venv $VenvDir
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
& $VenvPython -m pip install --upgrade pip setuptools wheel
& $VenvPython -m pip install (Join-Path $SrcDir "apps\worker")

Write-Log "正在安装 MCP Server 依赖" "Installing MCP server dependencies"
Push-Location (Join-Path $SrcDir "apps\mcp-server")
try {
    & npm ci
    & npm run build
} finally {
    Pop-Location
}

if (-not (Test-Path $McpServerPath)) {
    throw "Expected MCP server build artifact missing / 找不到预期的 MCP Server 构建产物: $McpServerPath"
}

$WorkerArgs = @(
    "-m", "aima_worker.main",
    "--platform-url", $PlatformUrl,
    "--runtime", $Runtime,
    "--mcp-server-path", $McpServerPath,
    "--bootstrap-code", $WorkerBootstrapCode,
    "--max-concurrent", $MaxConcurrent,
    "--max-budget-usd", $MaxBudgetUsd,
    "--max-turns", $MaxTurns,
    "--workspace-base-dir", (Join-Path $WorkRoot "workspaces")
)
if (-not [string]::IsNullOrWhiteSpace($WorkerName)) {
    $WorkerArgs += @("--name", $WorkerName)
}
if ($Runtime -eq "codex") {
    if (-not [string]::IsNullOrWhiteSpace($CodexHomeDir)) {
        $WorkerArgs += @("--codex-home-dir", $CodexHomeDir)
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexModel)) {
        $WorkerArgs += @("--codex-model", $CodexModel)
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexModelReasoningEffort)) {
        $WorkerArgs += @("--codex-model-reasoning-effort", $CodexModelReasoningEffort)
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexSandboxMode)) {
        $WorkerArgs += @("--codex-sandbox-mode", $CodexSandboxMode)
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexApprovalPolicy)) {
        $WorkerArgs += @("--codex-approval-policy", $CodexApprovalPolicy)
    }
}

$LogDir = Join-Path $WorkRoot "logs"
$StdoutLogPath = Join-Path $LogDir "worker.stdout.log"
$StderrLogPath = Join-Path $LogDir "worker.stderr.log"
$LauncherPath = Join-Path $WorkRoot "start-worker.cmd"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$CmdPathEntries = @(
    "$env:ProgramFiles\nodejs",
    "$env:AppData\npm",
    "$env:LocalAppData\Microsoft\WindowsApps"
)
$CmdWorkerArgs = ($WorkerArgs | ForEach-Object { New-QuotedCmdArgument $_ }) -join " "
$CmdPathPrefix = (($CmdPathEntries | Where-Object { Test-Path $_ }) | ForEach-Object {
    $_.Replace('"', '""')
}) -join ";"
$LauncherLines = [System.Collections.Generic.List[string]]::new()
foreach ($line in @(
    '@echo off',
    'setlocal enableextensions',
    ('set "AIMA_WORKER_HOME=' + ($WorkRoot -replace '"', '""') + '"'),
    ('set "AIMA_WORKER_VERSION=' + ($WorkerVersion -replace '"', '""') + '"'),
    'if not exist "%AIMA_WORKER_HOME%\logs" mkdir "%AIMA_WORKER_HOME%\logs"',
    ('set "PATH=' + $CmdPathPrefix + ';%PATH%"'),
    ('set "VENV_PYTHON=' + ($VenvPython -replace '"', '""') + '"'),
    ('set "WORKER_ARGS=' + ($CmdWorkerArgs -replace '"', '""') + '"'),
    ('set "STDOUT_LOG=' + ($StdoutLogPath -replace '"', '""') + '"'),
    ('set "STDERR_LOG=' + ($StderrLogPath -replace '"', '""') + '"')
)) {
    $LauncherLines.Add($line)
}
Add-LauncherEnvLine -Lines $LauncherLines -Name "HTTP_PROXY" -Value $HttpProxy
Add-LauncherEnvLine -Lines $LauncherLines -Name "HTTPS_PROXY" -Value $HttpsProxy
Add-LauncherEnvLine -Lines $LauncherLines -Name "ALL_PROXY" -Value $AllProxy
Add-LauncherEnvLine -Lines $LauncherLines -Name "NO_PROXY" -Value $NoProxy
foreach ($line in @(
    ('if /I "' + ($Runtime -replace '"', '""') + '"=="codex" set "CODEX_HOME=' + ($CodexHomeDir -replace '"', '""') + '"'),
    ':loop',
    'echo [%date% %time%] starting worker>>"%STDOUT_LOG%"',
    '"%VENV_PYTHON%" %WORKER_ARGS% 1>>"%STDOUT_LOG%" 2>>"%STDERR_LOG%"',
    'set "EXITCODE=%ERRORLEVEL%"',
    'echo [%date% %time%] worker exited with code %EXITCODE%, restarting in 5 seconds>>"%STDERR_LOG%"',
    'timeout /t 5 /nobreak >nul',
    'goto loop'
)) {
    $LauncherLines.Add($line)
}
$LauncherScript = $LauncherLines -join "`r`n"
Set-Content -Path $LauncherPath -Value $LauncherScript -Encoding ASCII

$TaskName = "AIMA-Worker"
$TaskCommand = "cmd.exe /d /c `"`"$LauncherPath`"`""

Write-Log "正在安装 AIMA Worker 计划任务" "Installing AIMA worker scheduled task"
& schtasks /Create /SC ONLOGON /TN $TaskName /TR $TaskCommand /F | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create scheduled task $TaskName / 创建计划任务失败"
}

Write-Log "正在启动 AIMA Worker" "Starting AIMA worker against $PlatformUrl"
& schtasks /Run /TN $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start scheduled task $TaskName / 启动计划任务失败"
}
Write-Log "Worker 已启动。日志路径：" "AIMA worker started via scheduled task. Logs: $StdoutLogPath / $StderrLogPath"
