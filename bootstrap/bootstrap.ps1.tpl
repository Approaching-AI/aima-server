$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Fix PowerShell 5.1 HTTP issues: disable Expect: 100-continue and enable modern TLS
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$ActivationCode = "__ACTIVATION_CODE__"
$BaseUrl = "__BASE_URL__"
$PollIntervalSeconds = [int]"__POLL_INTERVAL_SECONDS__"

$StateFile = Join-Path $env:USERPROFILE ".aima-device-state"
$script:ShowRawCommands = $false
if ($env:AIMA_SHOW_RAW_COMMANDS) {
    switch ($env:AIMA_SHOW_RAW_COMMANDS.ToLowerInvariant()) {
        "1" { $script:ShowRawCommands = $true }
        "true" { $script:ShowRawCommands = $true }
        "yes" { $script:ShowRawCommands = $true }
        "on" { $script:ShowRawCommands = $true }
    }
}

function Initialize-ConsoleEncoding {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    try {
        if ($Host -and $Host.Name -eq "ConsoleHost" -and (Get-Command chcp.com -ErrorAction SilentlyContinue)) {
            & chcp.com 65001 > $null
        }
    } catch { }

    try { [System.Console]::InputEncoding = $utf8NoBom } catch { }
    try { [System.Console]::OutputEncoding = $utf8NoBom } catch { }
    try { $global:OutputEncoding = $utf8NoBom } catch { }
}

function Save-DeviceState {
    @"
DEVICE_ID=$script:DeviceId
DEVICE_TOKEN=$script:DeviceToken
"@ | Set-Content -Path $StateFile -Encoding UTF8
}

function Load-DeviceState {
    if (Test-Path $StateFile) {
        $lines = Get-Content -Path $StateFile -Encoding UTF8
        foreach ($line in $lines) {
            if ($line -match '^DEVICE_ID=(.+)$') { $script:DeviceId = $Matches[1] }
            if ($line -match '^DEVICE_TOKEN=(.+)$') { $script:DeviceToken = $Matches[1] }
        }
        if ($script:DeviceId -and $script:DeviceToken) { return $true }
    }
    return $false
}

function Clear-DeviceState {
    $script:DeviceId = $null
    $script:DeviceToken = $null
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
}

function Get-MachineId {
    try {
        return (Get-ItemProperty `
            -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" `
            -Name MachineGuid `
            -ErrorAction Stop).MachineGuid
    } catch {
        return "$env:COMPUTERNAME" | ForEach-Object {
            [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($_)
                )
            ).Replace("-","").Substring(0,32).ToLower()
        }
    }
}

function Get-OSVersion {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.Caption) { return $os.Caption }
    } catch { }
    try {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.Caption) { return $os.Caption }
    } catch { }
    return [System.Environment]::OSVersion.VersionString
}

function Get-Architecture {
    try {
        $runtimeInfoType = [System.Type]::GetType("System.Runtime.InteropServices.RuntimeInformation")
        if ($runtimeInfoType) {
            $archProperty = $runtimeInfoType.GetProperty("OSArchitecture")
            if ($archProperty) {
                $archValue = $archProperty.GetValue($null, $null)
                if ($null -ne $archValue) { return $archValue.ToString() }
            }
        }
    } catch { }

    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if (-not $arch) {
        try {
            if ([System.Environment]::Is64BitOperatingSystem) { return "X64" }
            return "X86"
        } catch {
            return "Unknown"
        }
    }

    switch ($arch.ToUpperInvariant()) {
        "AMD64" { return "X64" }
        "X86" { return "X86" }
        "ARM64" { return "Arm64" }
        "ARM" { return "Arm" }
        default { return $arch }
    }
}

function Get-CommandPreview {
    param(
        [string]$Command,
        [int]$MaxLength = 96
    )

    if (-not $Command) {
        return "authorized task step"
    }

    $singleLine = (($Command -replace '\s+', ' ').Trim())
    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return $singleLine.Substring(0, $MaxLength - 3).TrimEnd() + "..."
}

function Get-PackageManagers {
    $mgrs = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) { $mgrs += "winget" }
    if (Get-Command choco  -ErrorAction SilentlyContinue) { $mgrs += "choco"  }
    if (Get-Command pip    -ErrorAction SilentlyContinue) { $mgrs += "pip"    }
    return @($mgrs)
}

function Get-Fingerprint {
    $osName = [System.Environment]::OSVersion.Platform.ToString()
    $osVersion = Get-OSVersion
    $arch = Get-Architecture
    $hostname = $env:COMPUTERNAME
    $machineId = Get-MachineId
    return "$osName|$osVersion|$arch|$hostname|$machineId"
}

function Get-OSProfile {
    $osName = [System.Environment]::OSVersion.Platform.ToString()
    $osVersion = Get-OSVersion
    $arch = Get-Architecture
    $hostname = $env:COMPUTERNAME
    $machineId = Get-MachineId
    $pkgMgrs = Get-PackageManagers

    return @{
        os_type = $osName
        os_version = $osVersion
        arch = $arch
        hostname = $hostname
        machine_id = $machineId
        package_managers = $pkgMgrs
        shell = "powershell"
    }
}

function Register-Device {
    $osProfile = Get-OSProfile
    $body = @{
        activation_code = $ActivationCode
        fingerprint = (Get-Fingerprint)
        os_profile = $osProfile
    } | ConvertTo-Json -Compress -Depth 3

    $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/devices/register" -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
    $script:DeviceId = $response.device_id
    $script:DeviceToken = $response.token

    if (-not $script:DeviceId -or -not $script:DeviceToken) {
        throw "Registration failed / 注册失败"
    }

    Write-Host ""
    Write-Host "  ● [AIMA] 设备注册成功 / Device registered: $script:DeviceId" -ForegroundColor Cyan
}

function Get-Headers {
    return @{
        Authorization = "Bearer $script:DeviceToken"
    }
}

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }

    try {
        return [int]$response.StatusCode
    } catch {
        try {
            return [int]$response.StatusCode.value__
        } catch {
            return $null
        }
    }
}

function Set-Offline {
    if ($script:DeviceId -and $script:DeviceToken) {
        try {
            Invoke-RestMethod -Method Post -Uri "$BaseUrl/devices/$script:DeviceId/offline" -Headers (Get-Headers) | Out-Null
        } catch {
        }
    }
}

function Renew-Token {
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/devices/$script:DeviceId/renew-token" -Headers (Get-Headers)
        if ($response.token) {
            $script:DeviceToken = $response.token
            Save-DeviceState
            Write-Host "  ● [AIMA] 凭证已更新 / Token renewed" -ForegroundColor Gray
        }
    } catch {
        $statusCode = Get-HttpStatusCode $_
        if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
            Write-Host "  ✖ [AIMA] 凭证无效或已过期，正在退出... / Device token invalid or expired; exiting." -ForegroundColor Red
            Write-Host "    (HTTP $statusCode)" -ForegroundColor Gray
            Clear-DeviceState
            throw
        }
    }
}

function Submit-CommandResult {
    param(
        [string]$Body
    )

    $attempt = 0
    while ($true) {
        try {
            Invoke-RestMethod -Method Post `
                -Uri "$BaseUrl/devices/$script:DeviceId/result" `
                -Headers (Get-Headers) `
                -ContentType "application/json; charset=utf-8" `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) | Out-Null
            return
        } catch {
            $attempt += 1
            $statusCode = Get-HttpStatusCode $_
            if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
                Write-Host "  ✖ [AIMA] 凭证无效或已过期，正在退出... / Device token invalid or expired; exiting." -ForegroundColor Red
                Write-Host "    (HTTP $statusCode)" -ForegroundColor Gray
                Clear-DeviceState
                throw
            }
            if ($statusCode -ge 400 -and $statusCode -lt 500) {
                Write-Host "  ✖ [AIMA] 结果被永久拒绝 / Command result rejected permanently (HTTP $statusCode)." -ForegroundColor Red
                throw
            }
            $delay = [Math]::Min([Math]::Max($attempt * 5, 5), 60)
            Write-Host "  ◌ [AIMA] 结果提交失败，${delay}s 后重试 (第 $attempt 次) / Result submit failed (attempt $attempt); retrying in ${delay}s" -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-FileText {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch {
        try {
            return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        } catch {
            return ""
        }
    }
}

function Get-FileTailText {
    param(
        [string]$Path,
        [int]$MaxChars = 4096
    )

    $text = Get-FileText -Path $Path
    if (-not $text) {
        return ""
    }
    if ($text.Length -gt $MaxChars) {
        return $text.Substring($text.Length - $MaxChars)
    }
    return $text
}

function Submit-CommandProgress {
    param(
        [string]$CommandId,
        [string]$StdoutText = "",
        [string]$StderrText = "",
        [string]$Message = ""
    )

    $body = @{
        stdout = $StdoutText
        stderr = $StderrText
    }
    if ($Message) {
        $body["message"] = if ($Message.Length -gt 500) { $Message.Substring(0, 500) } else { $Message }
    }
    $jsonBody = $body | ConvertTo-Json -Compress

    try {
        return Invoke-RestMethod -Method Post `
            -Uri "$BaseUrl/devices/$script:DeviceId/commands/$CommandId/progress" `
            -Headers (Get-Headers) `
            -TimeoutSec 10 `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody))
    } catch {
        $statusCode = Get-HttpStatusCode $_
        if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
            return [pscustomobject]@{
                ok = $false
                cancel_requested = $false
                command_status = $null
                auth_rejected = $true
            }
        }
        return $null
    }
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    try {
        if (Get-Command taskkill.exe -ErrorAction SilentlyContinue) {
            & taskkill.exe /F /T /PID $ProcessId *> $null
        }
    } catch { }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Invoke-DeviceCommand {
    param(
        [string]$CommandId,
        [string]$RawCommand,
        [string]$CommandEncoding = "",
        [int]$CommandTimeout = 300,
        [string]$CommandIntent = ""
    )

    # Decode base64-encoded commands (transparent transport)
    $Command = $RawCommand
    if ($CommandEncoding -eq "base64") {
        try {
            $Command = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String($RawCommand))
        } catch {
            Write-Host "[AIMA] Base64 decode failed, using raw command"
        }
    }

    if ($CommandIntent) {
        Write-Host "  ➜ [AIMA Agent] $CommandIntent" -ForegroundColor Cyan
    } else {
        $commandPreview = Get-CommandPreview -Command $Command
        Write-Host "  ➜ [AIMA Agent] 未提供步骤说明，正在执行已授权命令：$commandPreview / No step summary was provided; running authorized command: $commandPreview" -ForegroundColor Yellow
    }
    if ($script:ShowRawCommands) {
        Write-Host "    [AIMA] 正在执行 / Executing: $Command" -ForegroundColor Gray
    }
    $startedAt = Get-Date
    $stdoutText = ""
    $stderrText = ""
    $exitCode = 0

    $tmpScript = $null
    $tmpStdout = $null
    $tmpStderr = $null
    $process = $null

    try {
        $tmpBase = [System.Guid]::NewGuid().ToString()
        $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) "aima-$tmpBase.ps1"
        $tmpStdout = Join-Path ([System.IO.Path]::GetTempPath()) "aima-$tmpBase.stdout.log"
        $tmpStderr = Join-Path ([System.IO.Path]::GetTempPath()) "aima-$tmpBase.stderr.log"
        [System.IO.File]::WriteAllText($tmpScript, $Command, [System.Text.Encoding]::UTF8)

        $powershellExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        if (-not $powershellExe) {
            $powershellExe = "powershell.exe"
        }

        $process = Start-Process -FilePath $powershellExe `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tmpScript) `
            -PassThru `
            -RedirectStandardOutput $tmpStdout `
            -RedirectStandardError $tmpStderr `
            -WindowStyle Hidden

        $deadline = (Get-Date).AddSeconds($CommandTimeout)
        $nextProgressAt = (Get-Date).AddSeconds(5)
        $remoteCancelRequested = $false

        while (-not $process.HasExited) {
            if ((Get-Date) -ge $deadline) {
                Stop-ProcessTree -ProcessId $process.Id
                $process.WaitForExit(5000) | Out-Null
                $exitCode = 124
                $stderrText = "Command timed out after ${CommandTimeout}s"
                Write-Host "  ✖ [AIMA] 指令执行超时 (${CommandTimeout}s) / Command timed out." -ForegroundColor Red
                break
            }

            if ((Get-Date) -ge $nextProgressAt) {
                $elapsedSeconds = [int][Math]::Max(1, ((Get-Date) - $startedAt).TotalSeconds)
                $progressResponse = Submit-CommandProgress `
                    -CommandId $CommandId `
                    -StdoutText (Get-FileTailText -Path $tmpStdout) `
                    -StderrText (Get-FileTailText -Path $tmpStderr) `
                    -Message "Command still running (${elapsedSeconds}s)"
                $nextProgressAt = (Get-Date).AddSeconds(5)

                if (
                    $progressResponse -and (
                        $progressResponse.cancel_requested -eq $true -or
                        $progressResponse.command_status -eq "cancelled"
                    )
                ) {
                    Write-Host "  ✖ [AIMA] 收到远程取消请求，正在停止... / Cancellation requested remotely; stopping." -ForegroundColor Yellow
                    Stop-ProcessTree -ProcessId $process.Id
                    $process.WaitForExit(5000) | Out-Null
                    $exitCode = 130
                    $stderrText = "Command cancelled after remote request"
                    $remoteCancelRequested = $true
                    break
                }
            }

            $process.WaitForExit(1000) | Out-Null
        }

        if (-not $remoteCancelRequested -and $exitCode -ne 124) {
            $process.WaitForExit()
            $exitCode = [int]$process.ExitCode
        }

        $stdoutText = Get-FileText -Path $tmpStdout
        $capturedStderr = Get-FileText -Path $tmpStderr
        if ($capturedStderr) {
            if ($stderrText) {
                $stderrText = $capturedStderr + "`n" + $stderrText
            } else {
                $stderrText = $capturedStderr
            }
        }
    } catch {
        $exitCode = 1
        $stderrText = $_.Exception.Message
    } finally {
        foreach ($path in @($tmpScript, $tmpStdout, $tmpStderr)) {
            if ($path) {
                Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $script:ShowRawCommands) {
        $elapsedSeconds = [int][Math]::Max(1, ((Get-Date) - $startedAt).TotalSeconds)
        if ($exitCode -eq 0) {
            Write-Host "  ✔ [AIMA] 步骤已完成 / Step completed (${elapsedSeconds}s)" -ForegroundColor Green
        } else {
            Write-Host "  ✖ [AIMA] 步骤失败 / Step failed (exit $exitCode, ${elapsedSeconds}s)" -ForegroundColor Red
        }
    }

    if ($stdoutText.Length -gt 524288) {
        $stdoutText = $stdoutText.Substring(0, 524288)
    }
    if ($stderrText.Length -gt 524288) {
        $stderrText = $stderrText.Substring(0, 524288)
    }

    $resultId = [System.Guid]::NewGuid().ToString()

    $body = @{
        command_id = $CommandId
        exit_code = $exitCode
        stdout = $stdoutText
        stderr = $stderrText
        result_id = $resultId
    } | ConvertTo-Json -Compress

    Submit-CommandResult -Body $body
}

function Handle-Interaction {
    param(
        [string]$InteractionId,
        [string]$Question,
        [string]$InteractionType = "info_request"
    )

    if ($InteractionType -eq "notification") {
        Write-Host ""
        Write-Host "  ➜ [AIMA Agent]: $Question" -ForegroundColor Cyan
        $body = @{ answer = "displayed" } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Method Post `
                -Uri "$BaseUrl/devices/$script:DeviceId/interactions/$InteractionId/respond" `
                -Headers (Get-Headers) `
                -ContentType "application/json; charset=utf-8" `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        } catch { }
        return
    }

    if (-not [System.Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "  ➜ [AIMA Agent asks / 智能体提问]: $Question" -ForegroundColor Cyan
        $answer = Read-Host "  你的回答 / Your answer (直接回车可跳过)"
        if ($answer) {
            $body = @{ answer = $answer } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Method Post `
                    -Uri "$BaseUrl/devices/$script:DeviceId/interactions/$InteractionId/respond" `
                    -Headers (Get-Headers) `
                    -ContentType "application/json; charset=utf-8" `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            } catch { }
        }
    }
    # Non-interactive: silently skip
}

try {
    Initialize-ConsoleEncoding

    $reuseOk = $false
    if (Load-DeviceState) {
        Write-Host "  ● [AIMA] 发现已保存的状态，正在验证... / Found saved state, validating..." -ForegroundColor Gray
        try {
            Invoke-RestMethod -Method Get -Uri "$BaseUrl/devices/$script:DeviceId/poll?wait=0" -Headers (Get-Headers) -TimeoutSec 10 | Out-Null
            Write-Host "  ● [AIMA] 正在使用现有设备 / Reusing existing device: $script:DeviceId" -ForegroundColor Cyan
            $reuseOk = $true
        } catch {
            $sc = Get-HttpStatusCode $_
            Write-Host "  ● [AIMA] 状态无效，正在重新注册... / Saved state invalid (HTTP $sc), registering fresh." -ForegroundColor Yellow
            $script:DeviceId = $null
            $script:DeviceToken = $null
            Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $reuseOk) {
        Register-Device
        Save-DeviceState
    }
    $LastRenew = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $TokenRenewInterval = 86400  # 24 hours
    $RetryInterval = 3
    $MaxRetryInterval = 15

    while ($true) {
        $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($Now - $LastRenew) -ge $TokenRenewInterval) {
            Renew-Token
            $LastRenew = $Now
        }

        try {
            $pollResponse = Invoke-RestMethod -Method Get -Uri "$BaseUrl/devices/$script:DeviceId/poll?wait=10" -Headers (Get-Headers) -TimeoutSec 15
        } catch {
            $statusCode = Get-HttpStatusCode $_
            if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
                Write-Host "  ✖ [AIMA] 凭证无效或已过期，正在退出... / Device token invalid or expired; exiting." -ForegroundColor Red
                Write-Host "    (HTTP $statusCode)" -ForegroundColor Gray
                Clear-DeviceState
                break
            }
            Write-Host "  ◌ [AIMA] 轮询失败，${RetryInterval}s 后重试... / Poll failed, retrying in ${RetryInterval}s" -ForegroundColor Gray
            Start-Sleep -Seconds $RetryInterval
            $RetryInterval = [Math]::Min($RetryInterval * 2, $MaxRetryInterval)
            continue
        }
        $RetryInterval = 5

        if ($pollResponse.command_id -and $pollResponse.command) {
            $enc = if ($pollResponse.command_encoding) { $pollResponse.command_encoding } else { "" }
            $cmdTimeout = if ($pollResponse.command_timeout_seconds) { [int]$pollResponse.command_timeout_seconds } else { 300 }
            $cmdIntent = if ($pollResponse.command_intent) { [string]$pollResponse.command_intent } else { "" }
            Invoke-DeviceCommand -CommandId $pollResponse.command_id -RawCommand $pollResponse.command -CommandEncoding $enc -CommandTimeout $cmdTimeout -CommandIntent $cmdIntent
        }

        if ($pollResponse.interaction_id -and $pollResponse.question) {
            $interactionType = if ($pollResponse.interaction_type) { [string]$pollResponse.interaction_type } else { "info_request" }
            Handle-Interaction -InteractionId $pollResponse.interaction_id -Question $pollResponse.question -InteractionType $interactionType
        }
    }
} finally {
    Set-Offline
}
