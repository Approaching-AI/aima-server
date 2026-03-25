$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Fix PowerShell 5.1 HTTP issues
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$script:ApiBaseUrl = __BASE_URL__
$script:DefaultInviteCode = "openclaw-plugin"
$script:RegistrationRateLimitSummary = "OpenClaw 插件入口当前已限流，请等待补充额度后再试 / The OpenClaw plugin entry is rate limited. Please wait for more quota."
$script:DoctorDir = Join-Path $env:USERPROFILE ".openclaw\skills\aima-doctor"
$script:StateFile = Join-Path $env:USERPROFILE ".aima-device-state"
$script:CliStateFile = Join-Path $env:USERPROFILE ".aima-cli\device-state.json"
$script:PollInterval = 5
$script:DeviceId = $null
$script:DeviceToken = $null
$script:RecoveryCode = $null
$script:LastRegistrationFailureSummary = $null
$script:Symptom = ""
$script:IoMode = "jsonlines"   # jsonlines | terminal
$script:RunMode = ""           # "" = install, "run" = execute

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--run"          { $script:RunMode = "run" }
        "--terminal"     { $script:IoMode = "terminal" }
        "--symptom"      { $i++; $script:Symptom = [string]$args[$i] }
        "--platform-url" { $i++; $script:ApiBaseUrl = [string]$args[$i] }
    }
}

# ═══════════════════════════════════════════════════════════════════
# I/O layer
# ═══════════════════════════════════════════════════════════════════

function Write-JsonLine {
    param([hashtable]$Payload)
    Write-Output ($Payload | ConvertTo-Json -Compress)
}

function Emit-Message {
    param([string]$Text, [string]$Level = "info")
    if ($script:IoMode -eq "terminal") {
        switch ($Level) {
            "error" { Write-Host "  X $Text" -ForegroundColor Red }
            "warn"  { Write-Host "  ! $Text" -ForegroundColor Yellow }
            default { Write-Host "  * $Text" -ForegroundColor Green }
        }
    } else {
        Write-JsonLine @{
            type = "message"
            text = $Text
            level = $Level
        }
    }
}

function Emit-Status {
    param([string]$State, [string]$Detail = "")
    if ($script:IoMode -eq "terminal") {
        Write-Host ""
        Write-Host "[$State] $Detail" -ForegroundColor White
    } else {
        Write-JsonLine @{
            type = "status"
            state = $State
            detail = $Detail
        }
    }
}

function Emit-Prompt {
    param([string]$Id, [string]$Text)
    if ($script:IoMode -eq "terminal") {
        Write-Host ""
        Write-Host "  $Text" -ForegroundColor Cyan
        Write-Host "  > " -NoNewline
    } else {
        Write-JsonLine @{
            type = "prompt"
            id = $Id
            text = $Text
        }
    }
}

function Emit-CommandOutput {
    param([string]$Intent, [string]$Text)
    if ($script:IoMode -eq "terminal") {
        if ($Intent) { Write-Host "  -- $Intent --" -ForegroundColor DarkGray }
        Write-Host "  $Text"
    } else {
        $truncated = "false"
        if ($Text.Length -gt 4096) {
            $Text = $Text.Substring(0, 4096)
            $truncated = "true"
        }
        Write-JsonLine @{
            type = "command_output"
            intent = $Intent
            text = $Text
            truncated = ($truncated -eq "true")
        }
    }
}

function Emit-Done {
    param(
        [bool]$Success,
        [string]$Summary,
        [string]$TaskStatus = "",
        [Nullable[int]]$BudgetTasksRemaining = $null,
        [Nullable[int]]$BudgetTasksTotal = $null,
        [Nullable[double]]$BudgetUsdRemaining = $null,
        [Nullable[double]]$BudgetUsdTotal = $null,
        [string]$ReferralCode = "",
        [string]$ShareText = "",
        [string]$BindUrl = "",
        [string]$BindUserCode = ""
    )
    if ($script:IoMode -eq "terminal") {
        if ($Success) {
            Write-Host ""
            Write-Host "  OK: $Summary" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "  FAIL: $Summary" -ForegroundColor Red
        }
    } else {
        $payload = [ordered]@{
            type = "done"
            success = $Success
            summary = $Summary
        }
        if ($TaskStatus) { $payload.task_status = $TaskStatus }
        if ($null -ne $BudgetTasksRemaining) { $payload.budget_tasks_remaining = [int]$BudgetTasksRemaining }
        if ($null -ne $BudgetTasksTotal) { $payload.budget_tasks_total = [int]$BudgetTasksTotal }
        if ($null -ne $BudgetUsdRemaining) { $payload.budget_usd_remaining = [math]::Round([double]$BudgetUsdRemaining, 2) }
        if ($null -ne $BudgetUsdTotal) { $payload.budget_usd_total = [math]::Round([double]$BudgetUsdTotal, 2) }
        if ($ReferralCode) { $payload.referral_code = $ReferralCode }
        if ($ShareText) { $payload.share_text = $ShareText }
        if ($BindUrl) { $payload.bind_url = $BindUrl }
        if ($BindUserCode) { $payload.bind_user_code = $BindUserCode }
        Write-JsonLine $payload
    }
}

$script:ConflictAction = ""
$script:ConflictRestartSymptom = ""

function Test-ResumeAnswer {
    param([string]$Text)
    $normalized = ([string]$Text).Trim().ToLowerInvariant()
    return @("resume", "/aima resume", "继续", "继续跟进", "继续跟进当前任务", "继续当前任务") -contains $normalized
}

function Test-RestartAnswer {
    param([string]$Text)
    $trimmed = ([string]$Text).Trim()
    return (
        $trimmed -match '^(?i:restart)(\s+.+)?$' -or
        $trimmed -match '^(?i:/aima\s+restart)(\s+.+)?$' -or
        $trimmed -match '^重新开始(\s+.+)?$' -or
        $trimmed -match '^重新发起(\s+.+)?$'
    )
}

function Get-RestartSymptom {
    param([string]$Text)
    $trimmed = ([string]$Text).Trim()
    if ($trimmed -match '^(?i:/aima\s+restart)\s+(.+)$') { return $Matches[1].Trim() }
    if ($trimmed -match '^(?i:restart)\s+(.+)$') { return $Matches[1].Trim() }
    if ($trimmed -match '^重新开始\s+(.+)$') { return $Matches[1].Trim() }
    if ($trimmed -match '^重新发起\s+(.+)$') { return $Matches[1].Trim() }
    return ""
}

function Resolve-ExistingTaskConflict {
    $script:ConflictAction = ""
    $script:ConflictRestartSymptom = ""
    $promptText = "检测到上一次未完成的救援。请回复 /aima resume 继续跟进，或回复 /aima restart <问题> 重新开始。 / An unfinished rescue already exists. Reply with /aima resume to continue, or /aima restart <symptom> to start over."
    while ($true) {
        Emit-Prompt "task_conflict" $promptText
        if (-not (Read-Answer "task_conflict")) {
            Emit-Done -Success $false -Summary "Cancelled by user / 用户取消"
            return $false
        }
        if (Test-ResumeAnswer $script:Answer) {
            $script:ConflictAction = "resume"
            return $true
        }
        if (Test-RestartAnswer $script:Answer) {
            $script:ConflictAction = "restart"
            $script:ConflictRestartSymptom = Get-RestartSymptom $script:Answer
            return $true
        }
        Emit-Message "Reply with /aima resume or /aima restart <symptom> / 请回复 /aima resume 或 /aima restart <问题>" "warn"
    }
}

function Cancel-TaskById {
    param([string]$TaskId)
    if (-not $TaskId) {
        return $false
    }
    $resp = Invoke-DeviceApi -Method POST -Path "/devices/$($script:DeviceId)/tasks/$TaskId/cancel"
    if ($null -eq $resp) {
        return $false
    }
    return $resp.Status -eq 200
}

function Test-TransportInterruptionQuestion {
    param([string]$Text)
    $raw = [string]$Text
    $lowered = $raw.ToLowerInvariant()
    if (($lowered.Contains("offline") -or $lowered.Contains("disconnected")) -and (
        $lowered.Contains("ready") -or
        $lowered.Contains("reconnect") -or
        $lowered.Contains("restore network") -or
        $lowered.Contains("bring back online")
    )) {
        return $true
    }
    return (
        $raw.Contains("离线") -and (
            $raw.Contains("恢复联网") -or
            $raw.Contains("重新连上") -or
            $raw.Contains("重新连接") -or
            $raw.Contains("ready")
        )
    )
}

function Emit-TransportInterrupted {
    Emit-Done `
        -Success $false `
        -Summary "本地救援通道已中断，请重新发送 /aima <问题> 继续接管。 / The local rescue channel was interrupted. Send /aima <symptom> to take over again." `
        -TaskStatus "interrupted"
}

function Read-Answer {
    param([string]$ExpectedId = "")
    $script:Answer = $null
    $line = Read-Host
    if (-not $line) { return $false }
    if ($script:IoMode -eq "terminal") {
        $script:Answer = $line
    } else {
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.type -eq "cancel") { return $false }
            $script:Answer = $obj.text
        } catch {
            $script:Answer = $line
        }
    }
    return $true
}

# ═══════════════════════════════════════════════════════════════════
# HTTP helper
# ═══════════════════════════════════════════════════════════════════

function Invoke-Api {
    param(
        [string]$Method = "GET",
        [string]$Url,
        [hashtable]$Headers = @{},
        [string]$Body = $null
    )
    try {
        $params = @{
            Method = $Method
            Uri = $Url
            Headers = $Headers
            UseBasicParsing = $true
        }
        if ($Body) {
            $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $params.ContentType = "application/json; charset=utf-8"
        }
        $resp = Invoke-WebRequest @params
        return @{ Status = [int]$resp.StatusCode; Body = $resp.Content }
    } catch {
        $status = 0
        $body = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
            } catch { $body = $_.Exception.Message }
        }
        return @{ Status = $status; Body = $body }
    }
}

function Save-DoctorState {
    @(
        "DEVICE_ID=$($script:DeviceId)",
        "DEVICE_TOKEN=$($script:DeviceToken)",
        "RECOVERY_CODE=$($script:RecoveryCode)",
        "PLATFORM_URL=$($script:ApiBaseUrl)"
    ) | Set-Content $script:StateFile -Encoding UTF8
}

function Load-RecoveryCodeFromSavedState {
    if ($script:RecoveryCode) { return }

    if (Test-Path $script:CliStateFile) {
        try {
            $cliState = Get-Content $script:CliStateFile -Raw | ConvertFrom-Json
            if ($cliState.recovery_code) { $script:RecoveryCode = [string]$cliState.recovery_code }
            if ($cliState.platform_url) { $script:ApiBaseUrl = [string]$cliState.platform_url }
        } catch { }
    }

    if ((-not $script:RecoveryCode) -and (Test-Path $script:StateFile)) {
        $pairs = @{}
        Get-Content $script:StateFile | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') { $pairs[$matches[1]] = $matches[2] }
        }
        if ($pairs["RECOVERY_CODE"]) { $script:RecoveryCode = $pairs["RECOVERY_CODE"] }
        if ($pairs["PLATFORM_URL"]) { $script:ApiBaseUrl = $pairs["PLATFORM_URL"] }
    }
}

function Prompt-InviteCode {
    Emit-Prompt "reg_invite" "Please enter invite code / 请输入邀请码:"
    if (-not (Read-Answer "reg_invite")) { return $null }
    if (-not $script:Answer) {
        Emit-Message "Invite code required / 需要邀请码" "error"
        return ""
    }
    return [string]$script:Answer
}

function Prompt-RecoveryCode {
    Emit-Prompt "reg_recovery" "Please enter recovery code / 请输入恢复码:"
    if (-not (Read-Answer "reg_recovery")) { return $null }
    if (-not $script:Answer) {
        Emit-Message "Recovery code required / 需要恢复码" "error"
        return ""
    }
    return [string]$script:Answer
}

function Open-BrowserUrl {
    param([string]$Url)
    if (-not $Url) {
        return $false
    }
    try {
        Start-Process $Url | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Start-DoctorBrowserRecoveryFlow {
    param([Parameter(Mandatory=$true)][object]$Payload)

    $userCode = [string]$Payload.user_code
    $deviceCode = [string]$Payload.device_code
    $verificationUri = [string]$Payload.verification_uri
    $verificationUriComplete = [string]$Payload.verification_uri_complete
    $interval = 2
    if ($Payload.interval) {
        try { $interval = [int]$Payload.interval } catch { $interval = 2 }
    }
    if (-not $verificationUriComplete -and $verificationUri -and $userCode) {
        $verificationUriComplete = "$verificationUri?user_code=$([Uri]::EscapeDataString($userCode))"
    }

    if (-not $userCode -or -not $deviceCode -or -not $verificationUri) {
        Emit-Message "Server returned invalid recovery confirmation info / 服务器返回了无效的恢复确认信息" "error"
        return $false
    }

    Emit-Message "Confirm Device Recovery in Browser / 在浏览器中确认恢复设备" "info"
    Emit-Message "Open in browser: $verificationUriComplete / 在浏览器中打开: $verificationUriComplete" "info"
    Emit-Message "Enter device code: $userCode / 输入设备码: $userCode" "info"
    Emit-Message "Please sign in with the original device manager account to confirm recovery. / 请使用原来的 device manager 账号确认恢复。" "info"
    [void](Open-BrowserUrl -Url $verificationUriComplete)
    Emit-Message "Browser opened. Waiting for recovery confirmation... / 浏览器已打开。正在等待恢复确认..." "info"

    while ($true) {
        $pollResp = Invoke-Api -Method GET -Url "$($script:ApiBaseUrl)/device-flows/$deviceCode/poll"
        if (-not $pollResp.Body -or $pollResp.Status -ne 200) {
            Start-Sleep -Seconds $interval
            continue
        }

        try {
            $poll = $pollResp.Body | ConvertFrom-Json
        } catch {
            Start-Sleep -Seconds $interval
            continue
        }

        switch ([string]$poll.status) {
            "pending" {
                Start-Sleep -Seconds $interval
                continue
            }
            "bound" {
                if (-not $poll.device_id -or -not $poll.token -or -not $poll.recovery_code) {
                    Emit-Message "Recovery confirmation succeeded, but the platform returned incomplete credentials. / 恢复确认完成，但平台返回的凭据不完整。" "error"
                    return $false
                }
                $script:DeviceId = [string]$poll.device_id
                $script:DeviceToken = [string]$poll.token
                $script:RecoveryCode = [string]$poll.recovery_code
                Save-DoctorState
                Emit-Message "Browser confirmation complete. Device recovery succeeded. / 浏览器已确认，设备恢复成功。" "info"
                return $true
            }
            "expired" {
                Emit-Message "Recovery confirmation expired. Please rerun the device entry command. / 恢复确认已过期，请重新运行设备入口命令。" "error"
                return $false
            }
            "denied" {
                Emit-Message "Recovery confirmation was denied. Check the signed-in account or restart recovery. / 恢复确认被拒绝，请检查登录账号或重新发起恢复。" "error"
                return $false
            }
            default {
                Emit-Message "Recovery flow returned an unexpected status. / 恢复流程返回了未预期状态。" "error"
                return $false
            }
        }
    }
}

function Get-MachineId {
    try {
        return (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
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
    return [System.Environment]::OSVersion.VersionString
}

function Get-Architecture {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        "AMD64" { return "X64" }
        "ARM64" { return "Arm64" }
        default { return $arch }
    }
}

function Get-Fingerprint {
    $osName = [System.Environment]::OSVersion.Platform.ToString()
    $osVer = Get-OSVersion
    $arch = Get-Architecture
    return "$osName|$osVer|$arch|$env:COMPUTERNAME|$(Get-MachineId)"
}

function Get-HardwareId {
    $raw = Get-MachineId
    $bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($raw))
    return [System.BitConverter]::ToString($bytes).Replace("-","").ToLower()
}

function Get-OSProfile {
    return @{
        os_type     = [System.Environment]::OSVersion.Platform.ToString()
        os_version  = (Get-OSVersion)
        arch        = (Get-Architecture)
        hostname    = $env:COMPUTERNAME
        hardware_id = (Get-HardwareId)
        shell       = "powershell"
    }
}

function Register-OrRefreshDevice {
    param([string]$InviteCode = "", [bool]$RequireInvitePrompt = $false)

    $script:LastRegistrationFailureSummary = $null
    $osProfile = Get-OSProfile
    $fingerprint = Get-Fingerprint
    $hardwareId = Get-HardwareId
    $invite = $InviteCode

    if ($RequireInvitePrompt -and (-not $invite)) {
        $invite = Prompt-InviteCode
        if ($null -eq $invite) { return $null }
        if (-not $invite) { return $false }
    }

    while ($true) {
        $regPayload = @{
            fingerprint = $fingerprint
            hardware_id = $hardwareId
            os_profile  = $osProfile
        }
        if ($script:RecoveryCode) { $regPayload.recovery_code = $script:RecoveryCode }
        if ($invite) { $regPayload.invite_code = $invite }

        $regBody = $regPayload | ConvertTo-Json -Depth 5
        $resp = Invoke-Api -Method POST -Url "$($script:ApiBaseUrl)/devices/self-register" -Body $regBody

        if (-not $resp.Body) {
            Emit-Message "Cannot reach platform / 无法连接平台" "error"
            return $false
        }

        try { $regResult = $resp.Body | ConvertFrom-Json } catch {
            Emit-Message "Invalid response from platform" "error"
            return $false
        }

        if ($resp.Status -eq 200 -and $regResult.device_id -and $regResult.token) {
            $script:DeviceId = [string]$regResult.device_id
            $script:DeviceToken = [string]$regResult.token
            if ($regResult.recovery_code) { $script:RecoveryCode = [string]$regResult.recovery_code }
            Save-DoctorState
            return $true
        }

        if ($resp.Status -eq 409 -and [string]$regResult.reauth_method -eq "browser_confirmation") {
            return (Start-DoctorBrowserRecoveryFlow -Payload $regResult)
        }

        $detail = if ($regResult.detail) { [string]$regResult.detail } else { [string]$resp.Body }
        if (($resp.Status -eq 429) -or ($detail -match "openclaw plugin invite quota exhausted|wait for replenishment")) {
            $script:LastRegistrationFailureSummary = $script:RegistrationRateLimitSummary
            Emit-Message $script:RegistrationRateLimitSummary "warn"
            return $false
        }
        if (($detail -match "recovery_code") -and (-not $script:RecoveryCode)) {
            $providedRecovery = Prompt-RecoveryCode
            if ($null -eq $providedRecovery) { return $null }
            if (-not $providedRecovery) { return $false }
            $script:RecoveryCode = $providedRecovery
            continue
        }
        if (($detail -match "invite_code|worker_enrollment_code") -and (-not $invite)) {
            $invite = Prompt-InviteCode
            if ($null -eq $invite) { return $null }
            if (-not $invite) { return $false }
            continue
        }

        Emit-Message "Registration failed: $detail" "error"
        return $false
    }
}

function Refresh-DoctorCredentials {
    Load-RecoveryCodeFromSavedState
    Emit-Message "Device credentials expired, refreshing... / 设备凭证已过期，正在刷新..." "warn"
    $refreshed = Register-OrRefreshDevice
    if ($null -eq $refreshed) { return $null }
    if (-not $refreshed) { return $false }
    Emit-Message "Device credentials refreshed / 设备凭证已刷新" "info"
    return $true
}

function Invoke-DeviceApi {
    param(
        [string]$Method,
        [string]$Path,
        [string]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $($script:DeviceToken)" }
    $resp = Invoke-Api -Method $Method -Url "$($script:ApiBaseUrl)$Path" -Headers $headers -Body $Body
    if ($resp.Status -in 401, 403, 404) {
        $refreshed = Refresh-DoctorCredentials
        if ($null -eq $refreshed) { return $null }
        if (-not $refreshed) { return $resp }
        $headers = @{ Authorization = "Bearer $($script:DeviceToken)" }
        $resp = Invoke-Api -Method $Method -Url "$($script:ApiBaseUrl)$Path" -Headers $headers -Body $Body
    }
    return $resp
}

function Get-AccountBudgetSnapshot {
    if (-not $script:DeviceId -or -not $script:DeviceToken) {
        return $null
    }

    $resp = Invoke-DeviceApi -Method GET -Path "/devices/$($script:DeviceId)/account"
    if ($null -eq $resp -or $resp.Status -ne 200) {
        return $null
    }

    try {
        $account = $resp.Body | ConvertFrom-Json
    } catch {
        return $null
    }

    $tasksTotal = $null
    $tasksRemaining = $null
    $usdTotal = $null
    $usdRemaining = $null

    if ($null -ne $account.budget.max_tasks) {
        $tasksTotal = [int]$account.budget.max_tasks
        $usedTasks = 0
        if ($null -ne $account.budget.used_tasks) {
            $usedTasks = [int]$account.budget.used_tasks
        }
        $tasksRemaining = [math]::Max(0, $tasksTotal - $usedTasks)
    }

    if ($null -ne $account.budget.budget_usd) {
        $spentUsd = 0.0
        if ($null -ne $account.budget.spent_usd) {
            $spentUsd = [double]$account.budget.spent_usd
        }
        $usdTotal = [math]::Round([double]$account.budget.budget_usd, 2)
        $usdRemaining = [math]::Round([math]::Max(0.0, [double]$account.budget.budget_usd - $spentUsd), 2)
    }

    return @{
        BudgetTasksRemaining = $tasksRemaining
        BudgetTasksTotal = $tasksTotal
        BudgetUsdRemaining = $usdRemaining
        BudgetUsdTotal = $usdTotal
        ReferralCode = if ($account.referral_code) { [string]$account.referral_code } else { "" }
        ShareText = if ($account.share_text) { [string]$account.share_text } else { "" }
        IsBound = [bool]$account.is_bound
    }
}

function New-DeviceBindingLink {
    if (-not $script:DeviceId -or -not $script:DeviceToken) {
        return $null
    }

    $osProfile = Get-OSProfile
    $fingerprint = Get-Fingerprint
    $flowBody = @{
        device_id = $script:DeviceId
        fingerprint = $fingerprint
        os_profile = $osProfile
    } | ConvertTo-Json -Depth 5

    $resp = Invoke-DeviceApi -Method POST -Path "/device-flows" -Body $flowBody
    if ($null -eq $resp -or $resp.Status -ne 200) {
        return $null
    }

    try {
        $flow = $resp.Body | ConvertFrom-Json
    } catch {
        return $null
    }

    if (-not $flow.user_code -or -not $flow.verification_uri) {
        return $null
    }

    return @{
        BindUserCode = [string]$flow.user_code
        BindUrl = "$([string]$flow.verification_uri)?user_code=$([string]$flow.user_code)"
    }
}

# ═══════════════════════════════════════════════════════════════════
# Phase 0: Install mode
# ═══════════════════════════════════════════════════════════════════

if ($script:RunMode -ne "run") {
    New-Item -ItemType Directory -Force -Path $script:DoctorDir | Out-Null

    # Download bash version (best-effort for WSL/Git Bash)
    $rawBase = $script:ApiBaseUrl -replace '/api/v1$', ''
    try {
        Invoke-WebRequest -Uri "$rawBase/doctor?raw=1" -OutFile (Join-Path $script:DoctorDir "run.sh") -UseBasicParsing -ErrorAction Stop
    } catch { }

    # Download PowerShell version (this script itself)
    try {
        Invoke-WebRequest -Uri "$rawBase/doctor?raw=1&shell=powershell" -OutFile (Join-Path $script:DoctorDir "run.ps1") -UseBasicParsing -ErrorAction Stop
    } catch {
        # Fallback: write a placeholder
        "Write-Host 'AIMA Doctor: install incomplete. Re-run: iex (irm $rawBase/doctor)'" |
            Set-Content (Join-Path $script:DoctorDir "run.ps1") -Encoding UTF8
    }

    # Write config
    @{
        platform_url = $script:ApiBaseUrl
        installed_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        version      = "1.0.0"
    } | ConvertTo-Json | Set-Content (Join-Path $script:DoctorDir "config.json") -Encoding UTF8

    Write-Host ""
    Write-Host "  OK: AIMA Doctor installed" -ForegroundColor Green
    Write-Host "  Location: $($script:DoctorDir)"
    Write-Host "  Usage:"
    Write-Host "    IM:       /aima [symptom]"
    Write-Host "    Control:  /aima status | /aima cancel"
    Write-Host "    Legacy:   /askforhelp* | /doctor*"
    Write-Host "    Terminal: & '$($script:DoctorDir)\run.ps1' --run --terminal"
    Write-Host ""
    exit 0
}

# ═══════════════════════════════════════════════════════════════════
# Phase 1: Load device identity
# ═══════════════════════════════════════════════════════════════════

Emit-Status "collecting" "AIMA Doctor starting... / AIMA Doctor 启动中..."

# Try config.json for platform URL
$configPath = Join-Path $script:DoctorDir "config.json"
if (($script:ApiBaseUrl -eq "__BASE_URL__") -and (Test-Path $configPath)) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.platform_url) { $script:ApiBaseUrl = $cfg.platform_url }
    } catch { }
}

if (($script:ApiBaseUrl -eq "__BASE_URL__") -or (-not $script:ApiBaseUrl)) {
    Emit-Message "Cannot determine platform URL. Use --platform-url." "error"
    Emit-Done -Success $false -Summary "No platform URL configured"
    exit 1
}

# --- Identity resolution ---

# 1. Environment from OpenClaw
if ($env:OPENCLAW_DEVICE_ID -and $env:OPENCLAW_DEVICE_TOKEN) {
    $script:DeviceId = $env:OPENCLAW_DEVICE_ID
    $script:DeviceToken = $env:OPENCLAW_DEVICE_TOKEN
    $script:RecoveryCode = $env:OPENCLAW_RECOVERY_CODE
    Emit-Message "Device identity from OpenClaw env" "info"
}

# 2. CLI state (JSON)
elseif (Test-Path $script:CliStateFile) {
    try {
        $cliState = Get-Content $script:CliStateFile -Raw | ConvertFrom-Json
        if ($cliState.device_id -and $cliState.token) {
            $script:DeviceId = $cliState.device_id
            $script:DeviceToken = $cliState.token
            $script:RecoveryCode = $cliState.recovery_code
            if ($cliState.platform_url) { $script:ApiBaseUrl = $cliState.platform_url }
            Emit-Message "Device identity from CLI state" "info"
        }
    } catch { }
}

# 3. Bootstrap state (KEY=VALUE)
elseif (Test-Path $script:StateFile) {
    $pairs = @{}
    Get-Content $script:StateFile | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { $pairs[$matches[1]] = $matches[2] }
    }
    if ($pairs["DEVICE_ID"] -and $pairs["DEVICE_TOKEN"]) {
        $script:DeviceId = $pairs["DEVICE_ID"]
        $script:DeviceToken = $pairs["DEVICE_TOKEN"]
        $script:RecoveryCode = $pairs["RECOVERY_CODE"]
        if ($pairs["PLATFORM_URL"]) { $script:ApiBaseUrl = $pairs["PLATFORM_URL"] }
        Emit-Message "Device identity from local state" "info"
    }
}

# ═══════════════════════════════════════════════════════════════════
# Phase 1b: Register if needed
# ═══════════════════════════════════════════════════════════════════

if (-not $script:DeviceId -or -not $script:DeviceToken) {
    Emit-Status "registering" "Device not registered / 设备未注册"
    $registered = Register-OrRefreshDevice -InviteCode $script:DefaultInviteCode
    if ($null -eq $registered) {
        Emit-Done -Success $false -Summary "Registration cancelled"
        exit 1
    }
    if (-not $registered) {
        Emit-Done -Success $false -Summary $(if ($script:LastRegistrationFailureSummary) { $script:LastRegistrationFailureSummary } else { "Registration failed" })
        exit 1
    }
    Emit-Message "Device registered: $($script:DeviceId)" "info"
}

# ═══════════════════════════════════════════════════════════════════
# Phase 2: Collect diagnostics
# ═══════════════════════════════════════════════════════════════════

Emit-Status "collecting" "Collecting diagnostics... / 正在收集诊断信息..."

$diagLines = @()

# OpenClaw process
$ocProc = Get-Process -Name "*openclaw*" -ErrorAction SilentlyContinue
if ($ocProc) {
    $diagLines += "- openclaw_running: true (PID: $($ocProc.Id -join ', '))"
    Emit-Message "OpenClaw process running" "info"
} else {
    $diagLines += "- openclaw_running: false"
    Emit-Message "OpenClaw process NOT running" "warn"
}

# Config files
$configFound = $false
foreach ($cp in @(
    $env:OPENCLAW_CONFIG_PATH,
    (Join-Path $env:USERPROFILE ".openclaw\openclaw.json"),
    (Join-Path $env:USERPROFILE ".openclaw\config.json"),
    (Join-Path $env:USERPROFILE ".openclaw\config.yaml"),
    (Join-Path $env:APPDATA "openclaw\openclaw.json"),
    (Join-Path $env:APPDATA "openclaw\config.json")
)) {
    if (-not $cp) {
        continue
    }
    if (Test-Path $cp) {
        $diagLines += "- config_file: $cp (exists)"
        Emit-Message "Config found: $cp" "info"
        $configFound = $true
        break
    }
}
if (-not $configFound) {
    $diagLines += "- config_file: not found"
    Emit-Message "No config file found" "warn"
}

# Recent logs
$logFound = $false
foreach ($lp in @(
    (Join-Path $env:USERPROFILE ".openclaw\logs\latest.log"),
    (Join-Path $env:USERPROFILE ".openclaw\*.log")
)) {
    $logFiles = Get-Item $lp -ErrorAction SilentlyContinue
    if ($logFiles) {
        $logFile = $logFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $logTail = Get-Content $logFile.FullName -Tail 30 -ErrorAction SilentlyContinue
        $diagLines += "- recent_log: $($logFile.FullName)"
        $diagLines += "--- log start ---"
        $diagLines += ($logTail -join "`n")
        $diagLines += "--- log end ---"
        $logFound = $true
        break
    }
}
if (-not $logFound) {
    $diagLines += "- recent_log: no log file found"
}

# Disk space
try {
    $drive = (Get-PSDrive -Name ($env:USERPROFILE.Substring(0,1)) -ErrorAction Stop)
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    $diagLines += "- disk_free: ${freeGB}GB"
} catch {
    $diagLines += "- disk_free: unknown"
}

# Network
$rawBase = $script:ApiBaseUrl -replace '/api/v1$', ''
try {
    $healthResp = Invoke-WebRequest -Uri "$rawBase/healthz" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $diagLines += "- network: ok"
    Emit-Message "Network OK" "info"
} catch {
    $diagLines += "- network: unreachable"
    Emit-Message "Platform unreachable" "warn"
}

# OS info
$diagLines += "- os: $([System.Environment]::OSVersion.VersionString)"
$diagLines += "- hostname: $env:COMPUTERNAME"
$pyVer = try { python3 --version 2>$null } catch { "python3 not found" }
$nodeVer = try { node --version 2>$null } catch { "node not found" }
$diagLines += "- python: $pyVer"
$diagLines += "- node: $nodeVer"

# ═══════════════════════════════════════════════════════════════════
# Phase 3: Create diagnostic task
# ═══════════════════════════════════════════════════════════════════

Emit-Status "diagnosing" "Creating diagnosis task... / 正在创建诊断任务..."

$taskId = $null
while ($true) {
    $symptomText = if ($script:Symptom) { $script:Symptom } else { "User triggered /aima diagnosis / 用户通过 /aima 触发诊断" }
    $diagText = $diagLines -join "`n"
    $taskDesc = "OpenClaw doctor: $symptomText`n`nAuto-collected diagnostics:`n$diagText"
    $taskBody = @{ description = $taskDesc } | ConvertTo-Json -Depth 3
    $resp = Invoke-DeviceApi -Method POST -Path "/devices/$($script:DeviceId)/tasks" -Body $taskBody

    if ($null -eq $resp) {
        Emit-Done -Success $false -Summary "Registration cancelled"
        exit 1
    }
    if ($resp.Status -eq 200) {
        try { $taskResult = $resp.Body | ConvertFrom-Json } catch { }
        if ($taskResult -and $taskResult.task_id) {
            $taskId = [string]$taskResult.task_id
        }
        Emit-Message "Diagnosis task created, AI agent analyzing... / 诊断任务已创建，AI agent 正在分析..." "info"
        break
    }

    $detail = ""
    try { $detail = ($resp.Body | ConvertFrom-Json).detail } catch { $detail = $resp.Body }
    $activeTaskMatch = [regex]::Match([string]$detail, '^device already has active task:\s*(.+)$')
    if ($resp.Status -eq 409 -and $activeTaskMatch.Success) {
        $existingTaskId = $activeTaskMatch.Groups[1].Value.Trim()
        if (-not (Resolve-ExistingTaskConflict)) {
            exit 1
        }
        if ($script:ConflictAction -eq "resume") {
            $taskId = $existingTaskId
            Emit-Message "Continuing the unfinished rescue / 继续跟进上一次未完成的救援" "warn"
            break
        }
        if ($script:ConflictAction -eq "restart") {
            if ($script:ConflictRestartSymptom) {
                $script:Symptom = $script:ConflictRestartSymptom
            }
            if (-not (Cancel-TaskById $existingTaskId)) {
                Emit-Done -Success $false -Summary "Failed to cancel the previous rescue. Please try again. / 无法取消旧救援，请稍后重试" -TaskStatus "failed"
                exit 1
            }
            Emit-Message "Previous rescue cancelled; creating a new task / 已取消旧救援，正在重新创建任务" "warn"
            Start-Sleep -Seconds 1
            continue
        }
    }

    $budgetSnapshot = if ($resp.Status -eq 402) { Get-AccountBudgetSnapshot } else { $null }
    $bindLink = if ($budgetSnapshot -and (-not $budgetSnapshot.IsBound)) { New-DeviceBindingLink } else { $null }
    if ($budgetSnapshot) {
        Emit-Done `
            -Success $false `
            -Summary $(if ($detail) { [string]$detail } else { "Task creation failed" }) `
            -TaskStatus "failed" `
            -BudgetTasksRemaining $budgetSnapshot.BudgetTasksRemaining `
            -BudgetTasksTotal $budgetSnapshot.BudgetTasksTotal `
            -BudgetUsdRemaining $budgetSnapshot.BudgetUsdRemaining `
            -BudgetUsdTotal $budgetSnapshot.BudgetUsdTotal `
            -ReferralCode $budgetSnapshot.ReferralCode `
            -ShareText $budgetSnapshot.ShareText `
            -BindUrl $(if ($bindLink) { $bindLink.BindUrl } else { "" }) `
            -BindUserCode $(if ($bindLink) { $bindLink.BindUserCode } else { "" })
    } else {
        Emit-Done -Success $false -Summary $(if ($detail) { [string]$detail } else { "Task creation failed" }) -TaskStatus "failed"
    }
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# Phase 4: Poll loop
# ═══════════════════════════════════════════════════════════════════

Emit-Status "executing" "Waiting for AI agent... / 等待 AI agent..."

$answered = @()

while ($true) {
    $resp = Invoke-DeviceApi -Method GET -Path "/devices/$($script:DeviceId)/poll?wait=$($script:PollInterval)"
    if ($null -eq $resp) {
        Emit-Done -Success $false -Summary "Registration cancelled"
        exit 1
    }

    # Network error — retry
    if ($resp.Status -eq 0 -or $resp.Status -ge 500) {
        Start-Sleep -Seconds $script:PollInterval
        continue
    }

    try { $poll = $resp.Body | ConvertFrom-Json } catch { Start-Sleep -Seconds $script:PollInterval; continue }

    # --- Interaction ---
    if ($poll.interaction_id -and $poll.question) {
        if (Test-TransportInterruptionQuestion $poll.question) {
            Emit-TransportInterrupted
            exit 0
        }
        if ($answered -contains $poll.interaction_id) {
            Start-Sleep -Seconds 1
            continue
        }

        if ($poll.interaction_type -eq "notification") {
            $level = if ($poll.interaction_level) { [string]$poll.interaction_level } else { "info" }
            Emit-Message $poll.question $level
            $notifyBody = @{ answer = "displayed" } | ConvertTo-Json
            $notifyResp = Invoke-DeviceApi -Method POST `
                -Path "/devices/$($script:DeviceId)/interactions/$($poll.interaction_id)/respond" `
                -Body $notifyBody
            if ($null -eq $notifyResp) {
                Emit-Done -Success $false -Summary "Registration cancelled"
                exit 1
            }
            if ($notifyResp.Status -eq 200) {
                $answered += $poll.interaction_id
            }
            continue
        }

        Emit-Prompt $poll.interaction_id $poll.question
        if (Read-Answer $poll.interaction_id) {
            $ansBody = @{ answer = $script:Answer } | ConvertTo-Json
            $answerResp = Invoke-DeviceApi -Method POST `
                -Path "/devices/$($script:DeviceId)/interactions/$($poll.interaction_id)/respond" `
                -Body $ansBody
            if ($null -eq $answerResp) {
                Emit-Done -Success $false -Summary "Registration cancelled"
                exit 1
            }
            $answered += $poll.interaction_id
        } else {
            Emit-Done -Success $false -Summary "Cancelled by user"
            exit 0
        }
        continue
    }

    # --- Command ---
    if ($poll.command_id -and $poll.command) {
        $cmd = $poll.command
        if ($poll.command_encoding -eq "base64") {
            try { $cmd = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cmd)) } catch { }
        }
        $cmdIntent = if ($poll.command_intent) { $poll.command_intent } else { "command" }
        Emit-Message "Running: $cmdIntent / 正在执行: $cmdIntent" "info"

        $exitCode = 0
        $stdout = ""
        try {
            $stdout = Invoke-Expression $cmd 2>&1 | Out-String
        } catch {
            $stdout = $_.Exception.Message
            $exitCode = 1
        }

        Emit-CommandOutput $cmdIntent $stdout

        $resultBody = @{
            command_id = $poll.command_id
            exit_code  = $exitCode
            stdout     = $stdout
            stderr     = ""
            timed_out  = $false
        } | ConvertTo-Json

        $resultResp = Invoke-DeviceApi -Method POST `
            -Path "/devices/$($script:DeviceId)/result" `
            -Body $resultBody
        if ($null -eq $resultResp) {
            Emit-Done -Success $false -Summary "Registration cancelled"
            exit 1
        }
        continue
    }

    # --- Task completion ---
    if ($poll.notif_task_status) {
        $msg = if ($poll.notif_task_message) { $poll.notif_task_message } else { "Task $($poll.notif_task_status)" }
        $success = @("SUCCEEDED", "succeeded") -contains [string]$poll.notif_task_status
        $budgetSnapshot = Get-AccountBudgetSnapshot
        $bindLink = if ($budgetSnapshot -and (-not $budgetSnapshot.IsBound)) { New-DeviceBindingLink } else { $null }
        Emit-Done `
            -Success $success `
            -Summary $msg `
            -TaskStatus ([string]$poll.notif_task_status) `
            -BudgetTasksRemaining $(if ($null -ne $poll.notif_budget_tasks_remaining) { [int]$poll.notif_budget_tasks_remaining } else { $null }) `
            -BudgetTasksTotal $(if ($null -ne $poll.notif_budget_tasks_total) { [int]$poll.notif_budget_tasks_total } else { $null }) `
            -BudgetUsdRemaining $(if ($null -ne $poll.notif_budget_usd_remaining) { [double]$poll.notif_budget_usd_remaining } else { $null }) `
            -BudgetUsdTotal $(if ($null -ne $poll.notif_budget_usd_total) { [double]$poll.notif_budget_usd_total } else { $null }) `
            -ReferralCode $(if ($poll.notif_referral_code) { [string]$poll.notif_referral_code } else { "" }) `
            -ShareText $(if ($poll.notif_share_text) { [string]$poll.notif_share_text } else { "" }) `
            -BindUrl $(if ($bindLink) { $bindLink.BindUrl } else { "" }) `
            -BindUserCode $(if ($bindLink) { $bindLink.BindUserCode } else { "" })
        exit 0
    }

    # Nothing — wait
}
