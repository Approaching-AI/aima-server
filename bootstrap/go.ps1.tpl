$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Fix PowerShell 5.1 HTTP issues: disable Expect: 100-continue and enable modern TLS
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

# Path constants (no placeholder dependency — safe to define early)
$StateFile = Join-Path $env:USERPROFILE ".aima-device-state"

# ── Template placeholders (filled by server in curl|iex mode) ────
# Standalone-safe defaults; overridden by server-rendered values below.
$BaseUrl = $null
$PollIntervalSeconds = 5
$script:ReferralCode = $null
$WorkerEnrollmentCode = $null
$UtmSource = $null
$UtmMedium = $null
$UtmCampaign = $null
$script:InviteCode = $null
$script:UxManifestJson = $null
try {
    $BaseUrl = __BASE_URL__
    $PollIntervalSeconds = [int]"__POLL_INTERVAL_SECONDS__"
    $script:ReferralCode = __REFERRAL_CODE__
    $WorkerEnrollmentCode = __WORKER_CODE__
    $UtmSource = __UTM_SOURCE__
    $UtmMedium = __UTM_MEDIUM__
    $UtmCampaign = __UTM_CAMPAIGN__
    $script:InviteCode = __INVITE_CODE__
    $script:UxManifestJson = __UX_MANIFEST_JSON__
} catch {
    # Standalone mode: placeholders not filled by server. Preamble will bootstrap.
}

function Select-PreferredPlatformUrl {
    param(
        [string]$CurrentUrl,
        [string]$SavedUrl
    )

    if ($CurrentUrl -and $SavedUrl -and $CurrentUrl -match '^https://' -and $SavedUrl -notmatch '^https://') {
        return $CurrentUrl
    }

    return $SavedUrl
}

# ── Standalone mode bootstrap ────────────────────────────────────
# When installed via pip/npm/brew, template placeholders remain unfilled.
# Detect this and bootstrap configuration at runtime.
# In server-rendered mode (iex), this block is a no-op.
# Split sentinel so server-side rendering (which replaces __BASE_URL__ globally)
# cannot alter this detection.  PowerShell joins the halves at runtime.
$_unfilledSentinel = "__BASE" + "_URL__"
$_standaloneMode = [string]::IsNullOrEmpty($BaseUrl) -or ($BaseUrl -match [regex]::Escape($_unfilledSentinel))

if ($_standaloneMode) {
    $_savedUrl = $null

    # Priority 1: reuse platform URL from saved state (reconnect)
    if (Test-Path $StateFile) {
        foreach ($line in (Get-Content $StateFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^PLATFORM_URL=(.+)$') { $_savedUrl = $Matches[1] }
        }
    }
    # Priority 1b: cross-read from Python CLI JSON state
    if (-not $_savedUrl) {
        $cliState = Join-Path $env:USERPROFILE ".aima-cli" "device-state.json"
        if (Test-Path $cliState) {
            try {
                $cliData = Get-Content $cliState -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($cliData.platform_url) { $_savedUrl = $cliData.platform_url }
            } catch {}
        }
    }

    $_fallbackUrl = $null
    if ($env:AIMA_BASE_URL) {
        # Priority 2: explicit env var override
        $_fallbackUrl = "$($env:AIMA_BASE_URL.TrimEnd('/'))/api/v1"
    } else {
        # Priority 3: auto-detect region from culture/timezone
        $_region = "global"
        try {
            $culture = [System.Globalization.CultureInfo]::CurrentCulture.Name
            if ($culture -match '^zh') { $_region = "cn" }
        } catch {}
        if ($_region -eq "global") {
            try {
                $tz = [System.TimeZoneInfo]::Local.Id
                if ($tz -match 'China|Beijing|Shanghai') { $_region = "cn" }
            } catch {}
        }
        if ($_region -eq "cn") {
            $_fallbackUrl = "https://aimaserver.com/api/v1"
        } else {
            $_fallbackUrl = "https://aimaservice.ai/api/v1"
        }
    }
    if ($_savedUrl) {
        $BaseUrl = Select-PreferredPlatformUrl -CurrentUrl $_fallbackUrl -SavedUrl $_savedUrl
    } else {
        $BaseUrl = $_fallbackUrl
    }

    # Fetch UX manifest at runtime (variables are already $null from defaults
    # since the try block fails entirely when __BASE_URL__ is unfilled)
    if ([string]::IsNullOrEmpty($script:UxManifestJson)) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/ux-manifests/device-go" -TimeoutSec 10
            $script:UxManifestJson = $resp.Content
        } catch {
            $script:UxManifestJson = '{}'
        }
    }

    # Channel-specific default invite code: if no explicit invite code and
    # AIMA_ENTRY_CHANNEL is set by the distribution wrapper (npm/pip/brew),
    # use the channel's pre-seeded invite code as a fallback.
    if ([string]::IsNullOrEmpty($script:InviteCode) -and $env:AIMA_ENTRY_CHANNEL) {
        switch ($env:AIMA_ENTRY_CHANNEL) {
            "npm"  { $script:InviteCode = "channel-npm" }
            "pip"  { $script:InviteCode = "channel-pip" }
            "brew" { $script:InviteCode = "channel-brew" }
            "aima" { $script:InviteCode = "channel-aima" }
        }
    }
}
# ── End standalone mode bootstrap ────────────────────────────────

$RuntimeDir = Join-Path $env:USERPROFILE ".aima-device-runtime"
$script:OwnerScriptPath = Join-Path $RuntimeDir "go-owner.ps1"
$script:OwnerPidFile = Join-Path $RuntimeDir "owner.pid"
$script:OwnerLogFile = Join-Path $RuntimeDir "owner.log"
$script:OwnerErrorLogFile = Join-Path $RuntimeDir "owner.err.log"
$script:LauncherLogFile = Join-Path $RuntimeDir "launcher.log"
$script:OwnerHeartbeatFile = Join-Path $RuntimeDir "owner-heartbeat.json"
$script:OwnerHeartbeatStaleSeconds = 30
$script:SessionStatusFile = Join-Path $RuntimeDir "session-status.json"
$script:PendingInteractionFile = Join-Path $RuntimeDir "pending-interaction.json"
$script:InteractionAnswerFile = Join-Path $RuntimeDir "interaction-answer.json"
$script:TaskCompletionFile = Join-Path $RuntimeDir "task-completion.json"
$script:DisconnectRequestFile = Join-Path $RuntimeDir "disconnect.request"
$script:CommandExecutionRoot = Join-Path $RuntimeDir "executions"
$script:CommandResultTailMaxChars = 131072
$script:CommandProgressTailMaxChars = 4096
$script:ActiveTaskId = $null
$script:ConfirmedActiveTaskId = $null
$script:LastVisibleActiveTaskId = $null
$script:ActiveTaskLookupMisses = 0
$script:ActiveTaskLookupGraceMisses = 3
$script:GuidedTaskPrimaryAnswer = $null
$script:LocalCancelRequested = $false
$script:LastLocallyCancelledTaskId = $null
$script:TaskCancelHotkeyLabel = "Ctrl+K"
$script:BindConsoleHotkeyLabel = "Ctrl+B"
$script:DeviceDisconnectHotkeyLabel = "Ctrl+D"
$script:LastNotifiedTaskId = $null
$script:SessionStart = Get-Date
$script:ShowRawCommands = $false
$script:IsBound = $false
$script:RunAsOwner = $false
$script:ExplicitDisconnectRequested = $false
$script:AttachModeStarted = $false
$script:AttachModeFailed = $false
$script:UiExitRequested = $false
$script:AttachLastStatusKey = $null
$script:AttachLastInteractionId = $null
$script:AttachDeferredInteractionId = $null
$script:AttachInteractionRetryAfter = [int64]0
$script:AttachLastCompletionId = $null
$script:DeviceMaxTasks = $null
$script:DeviceUsedTasks = $null
$script:DeviceBudgetUsd = $null
$script:DeviceSpentUsd = $null
$script:UxManifest = $null
if ($env:AIMA_SHOW_RAW_COMMANDS) {
    switch ($env:AIMA_SHOW_RAW_COMMANDS.ToLowerInvariant()) {
        "1" { $script:ShowRawCommands = $true }
        "true" { $script:ShowRawCommands = $true }
        "yes" { $script:ShowRawCommands = $true }
        "on" { $script:ShowRawCommands = $true }
    }
}

for ($argIndex = 0; $argIndex -lt $args.Count; $argIndex++) {
    switch ($args[$argIndex]) {
        "--owner" {
            $script:RunAsOwner = $true
        }
        "--invite-code" {
            if ($argIndex + 1 -lt $args.Count) {
                $argIndex += 1
                $script:InviteCode = [string]$args[$argIndex]
            }
        }
        "--referral-code" {
            if ($argIndex + 1 -lt $args.Count) {
                $argIndex += 1
                $script:ReferralCode = [string]$args[$argIndex]
            }
        }
        "--worker-code" {
            if ($argIndex + 1 -lt $args.Count) {
                $argIndex += 1
                $WorkerEnrollmentCode = [string]$args[$argIndex]
            }
        }
    }
}

# ── Helpers ──────────────────────────────────────────────────────

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

function Resolve-UsableCommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        return $null
    }

    $source = $null
    foreach ($prop in @("Source", "Path", "Definition")) {
        if ($command.PSObject.Properties.Name -contains $prop) {
            $candidate = $command.$prop
            if ($candidate) {
                $source = [string]$candidate
                break
            }
        }
    }

    if (-not $source) {
        return $null
    }

    # Windows may expose python/python3 through Microsoft Store app execution aliases.
    # Executing those aliases before /go registers the device can pop the Store UI.
    if (($Name -ieq "python" -or $Name -ieq "python3") -and $source -match '[\\/]Microsoft[\\/]WindowsApps[\\/]') {
        return $null
    }

    return $source
}

function Get-UsablePython3Version {
    $pythonPath = Resolve-UsableCommandPath -Name "python3"
    if (-not $pythonPath) {
        return $null
    }

    try {
        $versionOutput = & $pythonPath --version 2>$null
        if ($versionOutput -match 'Python\s+(.+)') {
            return $matches[1]
        }
    } catch { }

    return $null
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

function Get-HardwareId {
    $raw = Get-MachineId
    $bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($raw))
    return [System.BitConverter]::ToString($bytes).Replace("-","").ToLower()
}

function Get-OSProfile {
    $osName = [System.Environment]::OSVersion.Platform.ToString()
    $osVersion = Get-OSVersion
    $arch = Get-Architecture
    $hostname = $env:COMPUTERNAME

    # Shell environment summary for agent context
    $proxyHttp = @($env:HTTP_PROXY, $env:http_proxy) | Where-Object { $_ } | Select-Object -First 1
    $proxyHttps = @($env:HTTPS_PROXY, $env:https_proxy) | Where-Object { $_ } | Select-Object -First 1
    $proxyNo = @($env:NO_PROXY, $env:no_proxy) | Where-Object { $_ } | Select-Object -First 1
    $nodeVer = try { (node --version 2>$null) } catch { $null }
    $pyVer = Get-UsablePython3Version

    return @{
        os_type     = $osName
        os_version  = $osVersion
        arch        = $arch
        hostname    = $hostname
        hardware_id = (Get-HardwareId)
        machine_id  = (Get-MachineId)
        package_managers = (Get-PackageManagers)
        shell       = "powershell"
        shell_env   = @{
            proxy = @{
                http_configured = [bool]$proxyHttp
                https_configured = [bool]$proxyHttps
                no_proxy_configured = [bool]$proxyNo
            }
            runtimes = @{ node = $nodeVer; python = $pyVer }
            locale = [System.Globalization.CultureInfo]::CurrentCulture.Name
        }
    }
}

function Get-Headers {
    return @{ Authorization = "Bearer $script:DeviceToken" }
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return $null }
    try { return [int]$response.StatusCode } catch {
        try { return [int]$response.StatusCode.value__ } catch { return $null }
    }
}

function Get-ErrorResponseText {
    param([Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return $null }
    try {
        $stream = $response.GetResponseStream()
        if ($null -eq $stream) { return $null }
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    } catch {
        return $null
    }
}

function Get-ErrorDetail {
    param([Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $bodyText = Get-ErrorResponseText -ErrorRecord $ErrorRecord
    if (-not $bodyText) { return $null }
    try {
        $payload = $bodyText | ConvertFrom-Json -ErrorAction Stop
        if ($payload.detail) {
            return [string]$payload.detail
        }
    } catch { }
    return $bodyText
}

function Get-ErrorPayload {
    param([Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $bodyText = Get-ErrorResponseText -ErrorRecord $ErrorRecord
    if (-not $bodyText) { return $null }
    try {
        return $bodyText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-UxManifest {
    if ($null -ne $script:UxManifest) {
        return $script:UxManifest
    }

    try {
        $script:UxManifest = $script:UxManifestJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $script:UxManifest = [pscustomobject]@{}
    }
    return $script:UxManifest
}

function Preserve-UxNodeValue {
    param([AllowNull()][object]$Value)

    if ($Value -is [System.Collections.IList] -and -not ($Value -is [string])) {
        return ,$Value
    }
    return $Value
}

function Get-UxNodeValue {
    param(
        [AllowNull()][object]$Node,
        [string]$Segment
    )

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Collections.IList] -and $Segment -match '^\d+$') {
        $index = [int]$Segment
        if ($index -ge 0 -and $index -lt $Node.Count) {
            return $Node[$index]
        }
        return $null
    }

    if ($Node -is [System.Collections.IDictionary]) {
        $value = $Node[$Segment]
        return Preserve-UxNodeValue -Value $value
    }

    $property = $Node.PSObject.Properties[$Segment]
    if ($null -ne $property) {
        $value = $property.Value
        return Preserve-UxNodeValue -Value $value
    }
    return $null
}

function Get-UxText {
    param(
        [string]$Path,
        [string]$Fallback = ""
    )

    $value = Get-UxManifest
    foreach ($segment in $Path.Split(".")) {
        if (-not $segment) { continue }
        $value = Get-UxNodeValue -Node $value -Segment $segment
        if ($null -eq $value) {
            return $Fallback
        }
    }

    if ($value -is [string] -and $value) {
        return $value
    }
    return $Fallback
}

$script:DisplayLanguage = ""

function Get-LangText {
    param(
        [string]$Zh,
        [string]$En
    )
    if ($script:DisplayLanguage -eq "zh_cn") { return $Zh }
    if ($script:DisplayLanguage -eq "en_us") { return $En }
    return "$Zh / $En"
}

function Get-UxTextLang {
    param(
        [string]$Path,
        [string]$Fallback = ""
    )
    if (-not $script:DisplayLanguage) {
        return Get-UxText -Path "$Path.text" -Fallback $Fallback
    }
    $langVal = Get-UxText -Path "$Path.$($script:DisplayLanguage)" -Fallback ""
    if ($langVal) { return $langVal }
    return Get-UxText -Path "$Path.text" -Fallback $Fallback
}

function Get-ShortInteractionText {
    param(
        [string]$Text,
        [int]$Limit = 88
    )

    if (-not $Text) {
        return ""
    }
    if ($Text.Length -le $Limit) {
        return $Text
    }
    return ($Text.Substring(0, [Math]::Max(0, $Limit - 3)).TrimEnd() + "...")
}

function Test-InteractionLineLooksCodeLike {
    param([string]$Line)

    if (-not $Line) {
        return $false
    }
    $trimmed = $Line.Trim()
    if (-not $trimmed) {
        return $false
    }
    if ($trimmed.StartsWith('```') -or $trimmed.StartsWith('{') -or $trimmed.StartsWith('[') -or $trimmed.StartsWith('PS ') -or $trimmed.StartsWith('> ') -or $trimmed.StartsWith('$ ') -or $trimmed.StartsWith('#!')) {
        return $true
    }
    if ($trimmed -match '^[ $A-Za-z_][A-Za-z0-9_:. -]*=') {
        return $true
    }
    if ($trimmed -match '(?i)(Invoke-RestMethod|Write-Output|ConvertTo-Json|Start-Process|Read-Host|Get-[A-Za-z]+|Set-[A-Za-z]+)|(^|\s)\$env:|(^|\s)\$[A-Za-z_][A-Za-z0-9_]*') {
        return $true
    }
    if ($trimmed -match '(?i)^(#!/|curl\b|bash\b|sh\b|zsh\b|sudo\b|chmod\b|export\b|apt(-get)?\b|brew\b|npm\b|pnpm\b|yarn\b|python3?\b)') {
        return $true
    }
    return $false
}

function Get-InteractionLeadLine {
    param([string]$Question)

    if (-not $Question) {
        return ""
    }
    foreach ($line in ($Question -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }
        $trimmed = $trimmed.TrimEnd(':', '：')
        if (Test-InteractionLineLooksCodeLike $trimmed) {
            continue
        }
        return $trimmed
    }
    return ""
}

function Get-InteractionQuestionKind {
    param([string]$Question)

    if (-not $Question) {
        return "plain"
    }
    $trimmed = $Question.TrimStart()
    if (($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) -and ($trimmed -match '[:\{\[]')) {
        return "json"
    }
    if ($Question -match '(?i)(Invoke-RestMethod|Write-Output|ConvertTo-Json|Start-Process|Read-Host|Get-[A-Za-z]+|Set-[A-Za-z]+)|(^|\s)\$env:|(^|\s)\$[A-Za-z_][A-Za-z0-9_]*') {
        return "powershell"
    }
    if ($Question -match '(?i)^(#!/|curl\b|bash\b|sh\b|zsh\b|sudo\b|chmod\b|export\b|apt(-get)?\b|brew\b|npm\b|pnpm\b|yarn\b|python3?\b)') {
        return "shell"
    }
    if ($Question -match "`n") {
        return "technical"
    }
    return "plain"
}

function Test-ShouldSimplifyInteractionQuestion {
    param([string]$Question)

    if (-not $Question) {
        return $false
    }
    $lines = @(
        ($Question -split "`r?`n") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($lines.Count -eq 0) {
        return $false
    }
    if ($lines.Count -le 3 -and $Question.Length -le 180) {
        $codeLike = $false
        foreach ($line in $lines) {
            if (Test-InteractionLineLooksCodeLike $line) {
                $codeLike = $true
                break
            }
        }
        if (-not $codeLike) {
            return $false
        }
    }
    if ($lines.Count -ge 6 -or $Question.Length -ge 260) {
        return $true
    }
    foreach ($line in $lines) {
        if ((Test-InteractionLineLooksCodeLike $line) -and ($lines.Count -gt 1 -or $Question.Length -gt 140)) {
            return $true
        }
    }
    return $false
}

function Format-InteractionQuestion {
    param(
        [string]$Question,
        [string]$DisplayQuestion = ""
    )

    if ($DisplayQuestion) {
        return $DisplayQuestion
    }
    if (-not (Test-ShouldSimplifyInteractionQuestion $Question)) {
        return $Question
    }

    $kind = Get-InteractionQuestionKind $Question
    $lead = Get-InteractionLeadLine $Question
    $headline = switch ($kind) {
        "powershell" { Get-LangText "智能体想让你确认一段 PowerShell 脚本或命令。" "The agent wants you to review a PowerShell script or command." }
        "shell" { Get-LangText "智能体想让你确认一段 Shell 脚本或命令。" "The agent wants you to review a shell script or command." }
        "json" { Get-LangText "智能体想让你确认一段配置或 JSON 内容。" "The agent wants you to review a config or JSON snippet." }
        default { Get-LangText "智能体发来了一段较长的技术内容，想请你确认或补充信息。" "The agent is asking about a longer technical snippet." }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($headline) | Out-Null
    if ($lead) {
        $focusPrefix = Get-LangText "重点" "Focus"
        $lines.Add(("{0}: {1}" -f $focusPrefix, (Get-ShortInteractionText -Text $lead -Limit 88))) | Out-Null
    }
    $lines.Add((Get-LangText "已简化显示，后台仍保留完整技术细节。" "Simplified for display; the full technical text is still preserved in the background.")) | Out-Null
    return ($lines -join [Environment]::NewLine)
}

$script:UxInvitePrompt = Get-UxText -Path "onboarding.invite_prompt.text" -Fallback "Please enter your invite or worker code / 请输入邀请码或 Worker 接入码:"
$script:UxInviteRequiredRedirected = Get-UxText -Path "onboarding.invite_required_noninteractive.text" -Fallback "Invite or worker code is required but stdin is redirected / 需要邀请码或 Worker 接入码但标准输入被重定向"
$script:UxInviteRequired = Get-UxText -Path "onboarding.invite_required.text" -Fallback "Invite or worker code is required / 需要邀请码或 Worker 接入码"
$script:UxReferralNeedsCode = Get-UxText -Path "onboarding.referral_requires_fresh_code.text" -Fallback "Referral link needs a fresh invite or worker code / 推荐链接当前需要新的邀请码或 Worker 接入码"
$script:UxFeedbackTitle = Get-UxText -Path "blocks.feedback_menu.title.text" -Fallback "What would you like to share? / 请选择反馈类型"
$script:UxFeedbackBugOption = Get-UxText -Path "blocks.feedback_menu.options.0.label.text" -Fallback "Report a problem / 反馈问题"
$script:UxFeedbackSuggestionOption = Get-UxText -Path "blocks.feedback_menu.options.1.label.text" -Fallback "Share a suggestion / 提建议"
$script:UxFeedbackGoBackOption = Get-UxText -Path "blocks.feedback_menu.options.2.label.text" -Fallback "Go back / 返回"
$script:UxFeedbackDescribePrompt = Get-UxText -Path "blocks.feedback_menu.prompt.text" -Fallback "Describe the issue (press Enter to skip) / 问题描述（直接回车跳过）:"
$script:UxPostTaskFeedbackPrompt = Get-UxText -Path "blocks.feedback_menu.footer.text" -Fallback "[f] Report a problem / 反馈问题  [s] Share a suggestion / 提建议  [Enter] Continue / 继续"
$script:UxTaskMenuReadyTitle = Get-UxText -Path "blocks.task_menu.title.text" -Fallback "What would you like me to help you do? / 请问你想让我帮你完成什么任务？"
$script:UxTaskMenuSubtitle = Get-UxText -Path "blocks.task_menu.subtitle.text" -Fallback "Describe the goal in one sentence. / 直接描述你的目标即可。"
$script:UxTaskMenuPrompt = Get-UxText -Path "blocks.task_menu.prompt.text" -Fallback "Type your task below: / 请输入任务："
$script:UxTaskMenuDisconnect = Get-UxText -Path "blocks.task_menu.context.disconnect_option_label.text" -Fallback "Disconnect device / 断开设备连接"
$script:UxTaskMenuFeedback = Get-UxText -Path "blocks.task_menu.options.2.label.text" -Fallback "Submit feedback or report a bug / 反馈问题或提建议"
$script:UxTaskMenuAction1 = Get-UxText -Path "blocks.task_menu.options.0.label.text" -Fallback "Install open-source software (Dify, OpenClaw, ComfyUI...) / 安装开源软件（Dify、OpenClaw、ComfyUI…）"
$script:UxTaskMenuAction2 = Get-UxText -Path "blocks.task_menu.options.1.label.text" -Fallback "Check or repair installed software / 检查或修复已安装的软件"
$script:UxTaskMenuSecretWarning = Get-UxText -Path "blocks.task_menu.context.secret_warning.text" -Fallback "Do not paste passwords / API keys / tokens directly. Describe where they are stored instead. / 不要直接粘贴密码 / API Key / Token 原文；只描述存放位置即可。"
$script:UxTaskMenuFreeformHint = Get-UxText -Path "blocks.task_menu.context.freeform_hint.text" -Fallback "Examples: / 例如："
$script:UxTaskMenuExample1 = Get-UxText -Path "blocks.task_menu.context.freeform_examples.0.text" -Fallback "Install OpenClaw, connect an LLM, and set up Feishu. / 帮我安装openclaw，连好大模型以及飞书"
$script:UxTaskMenuExample2 = Get-UxText -Path "blocks.task_menu.context.freeform_examples.1.text" -Fallback "Repair OpenClaw; Feishu is no longer receiving messages. / 修一下 openclaw，飞书收不到消息了"
$script:UxTaskMenuExample3 = Get-UxText -Path "blocks.task_menu.context.freeform_examples.2.text" -Fallback "Check Python version and upgrade to 3.12 if it is below 3.11. / 检查 python 版本，低于 3.11 就升级到 3.12"
$script:UxTaskMenuSubmitHint = Get-UxText -Path "blocks.task_menu.footer.text" -Fallback "[Enter] Submit / 提交需求   [Ctrl+D] Disconnect / 断开设备   [Ctrl+C] Exit UI / 退出界面"
$script:UxTaskMenuResumeHotkeyHint = Get-UxText -Path "blocks.task_menu.context.resume_hotkey_hint.text" -Fallback "快捷键 Hotkey: Ctrl+K 取消当前任务 / Ctrl+D 断开设备 / Ctrl+C 退出界面"
$script:UxActiveTaskTitle = Get-UxText -Path "blocks.active_task_resolution.title.text" -Fallback "An unfinished task was found from a previous session. / 发现上次会话遗留的未完成任务。"
$script:UxActiveTaskPrompt = Get-UxText -Path "blocks.active_task_resolution.prompt.text" -Fallback "Choose how to handle the unfinished task: / 请选择如何处理这个未完成任务："
$script:UxActiveTaskTaskIdLabel = Get-UxText -Path "blocks.active_task_resolution.context.task_id_label.text" -Fallback "Task ID / 任务 ID"
$script:UxActiveTaskStatusLabel = Get-UxText -Path "blocks.active_task_resolution.context.status_label.text" -Fallback "Status / 状态"
$script:UxActiveTaskTargetLabel = Get-UxText -Path "blocks.active_task_resolution.context.target_label.text" -Fallback "Target / 目标"
$script:UxActiveTaskResumeLabel = Get-UxText -Path "blocks.active_task_resolution.options.0.label.text" -Fallback "Resume task now / 立即继续任务"
$script:UxActiveTaskCancelLabel = Get-UxText -Path "blocks.active_task_resolution.options.1.label.text" -Fallback "Cancel current task / 取消当前任务"
$script:UxActiveTaskDisconnectLabel = Get-UxText -Path "blocks.active_task_resolution.options.2.label.text" -Fallback "Disconnect device / 断开设备连接"
$script:UxActiveTaskNonInteractiveNotice = Get-UxText -Path "blocks.active_task_resolution.context.noninteractive_resume_notice.text" -Fallback "Non-interactive attach detected; resuming this task by default. / 当前是非交互式附着，默认继续该任务。"
$script:UxActiveTaskInputUnavailableNotice = Get-UxText -Path "blocks.active_task_resolution.context.input_unavailable_resume_notice.text" -Fallback "Input is unavailable; resuming this task by default. / 当前输入不可用，默认继续该任务。"
$script:UxActiveTaskInvalidNotice = Get-UxText -Path "blocks.active_task_resolution.context.invalid_selection_notice.text" -Fallback "Please choose 1 / 2 or d. / 请输入 1 / 2 或 d。"
$script:UxInteractionTitle = Get-UxText -Path "blocks.interaction_prompt.title.text" -Fallback "AIMA Agent asks / 智能体提问"
$script:UxInteractionPrompt = Get-UxText -Path "blocks.interaction_prompt.prompt.text" -Fallback "你的回答 / Your answer (直接回车可跳过): "
$script:UxInteractionSkipNotice = Get-UxText -Path "blocks.interaction_prompt.context.skip_notice.text" -Fallback "已跳过，问题会继续保留在后台。 / Skipped; the question stays pending in the background."
$script:UxInteractionQueuedNotice = Get-UxText -Path "blocks.interaction_prompt.context.queued_notice.text" -Fallback "已记录你的回答，后台继续处理中。 / Your answer was queued and the background session is continuing."
$script:UxTaskCompletionSuccessTitle = Get-UxText -Path "blocks.task_completion.context.success_title.text" -Fallback "Task reported complete / 任务已报告完成"
$script:UxTaskCompletionFailureTitle = Get-UxText -Path "blocks.task_completion.context.failure_title.text" -Fallback "Task failed / 任务失败"
$script:UxTaskCompletionBudgetLabel = Get-UxText -Path "blocks.task_completion.context.budget_remaining_label.text" -Fallback "Tasks remaining / 剩余额度"
$script:UxTaskCompletionShareHeading = Get-UxText -Path "blocks.task_completion.context.share_heading.text" -Fallback "Share to earn rewards / 邀请好友得奖励"
$script:UxTaskCompletionSharePrompt = Get-UxText -Path "blocks.task_completion.context.copy_share_prompt.text" -Fallback "[c] 复制分享文案 / Copy share text  [Enter] 继续 / Continue"
$script:UxTaskCompletionBindPrompt = Get-UxText -Path "blocks.task_completion.context.bind_console_prompt.text" -Fallback "Press Ctrl+B to bind this device to console. / 按 Ctrl+B 将这台设备绑定到控制台。"
$script:UxTaskCompletionCopiedNotice = Get-UxText -Path "blocks.task_completion.context.copied_notice.text" -Fallback "Copied to clipboard / 已复制到剪贴板"
$script:UxRuntimeKeepOpen = Get-UxText -Path "runtime.keep_window_open.text" -Fallback "这一步可能需要几分钟，请保持窗口开启。 / This step may take a few minutes; keep this window open."
$script:UxRuntimeRemoteCancel = Get-UxText -Path "runtime.remote_cancel_requested.text" -Fallback "收到远程取消请求，正在停止当前步骤。 / Cancellation was requested remotely; stopping this step."
$script:UxRuntimeAnswerQueued = Get-UxText -Path "runtime.answer_queued.text" -Fallback "已记录你的回答，后台继续处理中 / Your answer was queued and the background session is continuing."
$script:UxBackgroundSessionBooting = Get-UxText -Path "background.session_booting.text" -Fallback "后台会话正在本机恢复，即将重新连接。 / Background session is starting locally; reconnecting soon."
$script:UxBackgroundSessionStarted = Get-UxText -Path "background.session_started.text" -Fallback "设备已连接，后台等待指令。 / Device linked and waiting in the background."
$script:UxBrandName = Get-UxText -Path "context.brand_name.text" -Fallback "AIMA灵机"
$script:UxBrandSlogan = Get-UxText -Path "context.brand_slogan.text" -Fallback "一条命令，AI 接管运维 / One command. AI takes over ops."
$script:UxWindowTitle = Get-UxText -Path "context.window_title.text" -Fallback "AIMA灵机：一条命令，AI 接管运维 / AIMA灵机: One command. AI takes over ops."

function Get-GuidedFlowTextLang {
    param(
        [string]$FlowKey,
        [string]$Field,
        [string]$Fallback = ""
    )
    return Get-UxTextLang -Path "blocks.task_menu.context.guided_flows.$FlowKey.$Field" -Fallback $Fallback
}

function Get-GuidedFlowStepTextLang {
    param(
        [string]$FlowKey,
        [int]$Index,
        [string]$Field,
        [string]$Fallback = ""
    )
    return Get-UxTextLang -Path "blocks.task_menu.context.guided_flows.$FlowKey.steps.$Index.$Field" -Fallback $Fallback
}

function Reload-UxStrings {
    $script:UxInvitePrompt = Get-UxTextLang -Path "onboarding.invite_prompt" -Fallback "Please enter your invite or worker code / 请输入邀请码或 Worker 接入码:"
    $script:UxInviteRequiredRedirected = Get-UxTextLang -Path "onboarding.invite_required_noninteractive" -Fallback "Invite or worker code is required but stdin is redirected / 需要邀请码或 Worker 接入码但标准输入被重定向"
    $script:UxInviteRequired = Get-UxTextLang -Path "onboarding.invite_required" -Fallback "Invite or worker code is required / 需要邀请码或 Worker 接入码"
    $script:UxReferralNeedsCode = Get-UxTextLang -Path "onboarding.referral_requires_fresh_code" -Fallback "Referral link needs a fresh invite or worker code / 推荐链接当前需要新的邀请码或 Worker 接入码"
    $script:UxFeedbackTitle = Get-UxTextLang -Path "blocks.feedback_menu.title" -Fallback "What would you like to share? / 请选择反馈类型"
    $script:UxFeedbackBugOption = Get-UxTextLang -Path "blocks.feedback_menu.options.0.label" -Fallback "Report a problem / 反馈问题"
    $script:UxFeedbackSuggestionOption = Get-UxTextLang -Path "blocks.feedback_menu.options.1.label" -Fallback "Share a suggestion / 提建议"
    $script:UxFeedbackGoBackOption = Get-UxTextLang -Path "blocks.feedback_menu.options.2.label" -Fallback "Go back / 返回"
    $script:UxFeedbackDescribePrompt = Get-UxTextLang -Path "blocks.feedback_menu.prompt" -Fallback "Describe the issue (press Enter to skip) / 问题描述（直接回车跳过）:"
    $script:UxPostTaskFeedbackPrompt = Get-UxTextLang -Path "blocks.feedback_menu.footer" -Fallback "[f] Report a problem / 反馈问题  [s] Share a suggestion / 提建议  [Enter] Continue / 继续"
    $script:UxTaskMenuReadyTitle = Get-UxTextLang -Path "blocks.task_menu.title" -Fallback "What would you like me to help you do? / 请问你想让我帮你完成什么任务？"
    $script:UxTaskMenuSubtitle = Get-UxTextLang -Path "blocks.task_menu.subtitle" -Fallback "Describe the goal in one sentence. / 直接描述你的目标即可。"
    $script:UxTaskMenuPrompt = Get-UxTextLang -Path "blocks.task_menu.prompt" -Fallback "Type your task below: / 请输入任务："
    $script:UxTaskMenuDisconnect = Get-UxTextLang -Path "blocks.task_menu.context.disconnect_option_label" -Fallback "Disconnect device / 断开设备连接"
    $script:UxTaskMenuFeedback = Get-UxTextLang -Path "blocks.task_menu.options.2.label" -Fallback "Submit feedback or report a bug / 反馈问题或提建议"
    $script:UxTaskMenuAction1 = Get-UxTextLang -Path "blocks.task_menu.options.0.label" -Fallback "Install open-source software (Dify, OpenClaw, ComfyUI...) / 安装开源软件（Dify、OpenClaw、ComfyUI…）"
    $script:UxTaskMenuAction2 = Get-UxTextLang -Path "blocks.task_menu.options.1.label" -Fallback "Check or repair installed software / 检查或修复已安装的软件"
    $script:UxTaskMenuSecretWarning = Get-UxTextLang -Path "blocks.task_menu.context.secret_warning" -Fallback "Do not paste passwords / API keys / tokens directly. Describe where they are stored instead. / 不要直接粘贴密码 / API Key / Token 原文；只描述存放位置即可。"
    $script:UxTaskMenuFreeformHint = Get-UxTextLang -Path "blocks.task_menu.context.freeform_hint" -Fallback "Examples: / 例如："
    $script:UxTaskMenuExample1 = Get-UxTextLang -Path "blocks.task_menu.context.freeform_examples.0" -Fallback "Install OpenClaw, connect an LLM, and set up Feishu. / 帮我安装openclaw，连好大模型以及飞书"
    $script:UxTaskMenuExample2 = Get-UxTextLang -Path "blocks.task_menu.context.freeform_examples.1" -Fallback "Repair OpenClaw; Feishu is no longer receiving messages. / 修一下 openclaw，飞书收不到消息了"
    $script:UxTaskMenuExample3 = Get-UxTextLang -Path "blocks.task_menu.context.freeform_examples.2" -Fallback "Check Python version and upgrade to 3.12 if it is below 3.11. / 检查 python 版本，低于 3.11 就升级到 3.12"
    $script:UxTaskMenuSubmitHint = Get-UxTextLang -Path "blocks.task_menu.footer" -Fallback "[Enter] Submit / 提交需求   [Ctrl+D] Disconnect / 断开设备   [Ctrl+C] Exit UI / 退出界面"
    $script:UxTaskMenuResumeHotkeyHint = Get-UxTextLang -Path "blocks.task_menu.context.resume_hotkey_hint" -Fallback "快捷键 Hotkey: Ctrl+K 取消当前任务 / Ctrl+D 断开设备 / Ctrl+C 退出界面"
    $script:UxActiveTaskTitle = Get-UxTextLang -Path "blocks.active_task_resolution.title" -Fallback "An unfinished task was found from a previous session. / 发现上次会话遗留的未完成任务。"
    $script:UxActiveTaskPrompt = Get-UxTextLang -Path "blocks.active_task_resolution.prompt" -Fallback "Choose how to handle the unfinished task: / 请选择如何处理这个未完成任务："
    $script:UxActiveTaskTaskIdLabel = Get-UxTextLang -Path "blocks.active_task_resolution.context.task_id_label" -Fallback "Task ID / 任务 ID"
    $script:UxActiveTaskStatusLabel = Get-UxTextLang -Path "blocks.active_task_resolution.context.status_label" -Fallback "Status / 状态"
    $script:UxActiveTaskTargetLabel = Get-UxTextLang -Path "blocks.active_task_resolution.context.target_label" -Fallback "Target / 目标"
    $script:UxActiveTaskResumeLabel = Get-UxTextLang -Path "blocks.active_task_resolution.options.0.label" -Fallback "Resume task now / 立即继续任务"
    $script:UxActiveTaskCancelLabel = Get-UxTextLang -Path "blocks.active_task_resolution.options.1.label" -Fallback "Cancel current task / 取消当前任务"
    $script:UxActiveTaskDisconnectLabel = Get-UxTextLang -Path "blocks.active_task_resolution.options.2.label" -Fallback "Disconnect device / 断开设备连接"
    $script:UxActiveTaskNonInteractiveNotice = Get-UxTextLang -Path "blocks.active_task_resolution.context.noninteractive_resume_notice" -Fallback "Non-interactive attach detected; resuming this task by default. / 当前是非交互式附着，默认继续该任务。"
    $script:UxActiveTaskInputUnavailableNotice = Get-UxTextLang -Path "blocks.active_task_resolution.context.input_unavailable_resume_notice" -Fallback "Input is unavailable; resuming this task by default. / 当前输入不可用，默认继续该任务。"
    $script:UxActiveTaskInvalidNotice = Get-UxTextLang -Path "blocks.active_task_resolution.context.invalid_selection_notice" -Fallback "Please choose 1 / 2 or d. / 请输入 1 / 2 或 d。"
    $script:UxInteractionTitle = Get-UxTextLang -Path "blocks.interaction_prompt.title" -Fallback "AIMA Agent asks / 智能体提问"
    $script:UxInteractionPrompt = Get-UxTextLang -Path "blocks.interaction_prompt.prompt" -Fallback "你的回答 / Your answer (直接回车可跳过): "
    $script:UxInteractionSkipNotice = Get-UxTextLang -Path "blocks.interaction_prompt.context.skip_notice" -Fallback "已跳过，问题会继续保留在后台。 / Skipped; the question stays pending in the background."
    $script:UxInteractionQueuedNotice = Get-UxTextLang -Path "blocks.interaction_prompt.context.queued_notice" -Fallback "已记录你的回答，后台继续处理中。 / Your answer was queued and the background session is continuing."
    $script:UxTaskCompletionSuccessTitle = Get-UxTextLang -Path "blocks.task_completion.context.success_title" -Fallback "Task reported complete / 任务已报告完成"
    $script:UxTaskCompletionFailureTitle = Get-UxTextLang -Path "blocks.task_completion.context.failure_title" -Fallback "Task failed / 任务失败"
    $script:UxTaskCompletionBudgetLabel = Get-UxTextLang -Path "blocks.task_completion.context.budget_remaining_label" -Fallback "Tasks remaining / 剩余额度"
    $script:UxTaskCompletionShareHeading = Get-UxTextLang -Path "blocks.task_completion.context.share_heading" -Fallback "Share to earn rewards / 邀请好友得奖励"
    $script:UxTaskCompletionSharePrompt = Get-UxTextLang -Path "blocks.task_completion.context.copy_share_prompt" -Fallback "[c] 复制分享文案 / Copy share text  [Enter] 继续 / Continue"
    $script:UxTaskCompletionBindPrompt = Get-UxTextLang -Path "blocks.task_completion.context.bind_console_prompt" -Fallback "Press Ctrl+B to bind this device to console. / 按 Ctrl+B 将这台设备绑定到控制台。"
    $script:UxTaskCompletionCopiedNotice = Get-UxTextLang -Path "blocks.task_completion.context.copied_notice" -Fallback "Copied to clipboard / 已复制到剪贴板"
    $script:UxRuntimeKeepOpen = Get-UxTextLang -Path "runtime.keep_window_open" -Fallback "这一步可能需要几分钟，请保持窗口开启。 / This step may take a few minutes; keep this window open."
    $script:UxRuntimeRemoteCancel = Get-UxTextLang -Path "runtime.remote_cancel_requested" -Fallback "收到远程取消请求，正在停止当前步骤。 / Cancellation was requested remotely; stopping this step."
    $script:UxRuntimeAnswerQueued = Get-UxTextLang -Path "runtime.answer_queued" -Fallback "已记录你的回答，后台继续处理中 / Your answer was queued and the background session is continuing."
    $script:UxBackgroundSessionBooting = Get-UxTextLang -Path "background.session_booting" -Fallback "后台会话正在本机恢复，即将重新连接。 / Background session is starting locally; reconnecting soon."
    $script:UxBackgroundSessionStarted = Get-UxTextLang -Path "background.session_started" -Fallback "设备已连接，后台等待指令。 / Device linked and waiting in the background."
    $script:UxBrandName = Get-UxTextLang -Path "context.brand_name" -Fallback "AIMA灵机"
    $script:UxBrandSlogan = Get-UxTextLang -Path "context.brand_slogan" -Fallback "一条命令，AI 接管运维 / One command. AI takes over ops."
    $script:UxWindowTitle = Get-UxTextLang -Path "context.window_title" -Fallback "AIMA灵机：一条命令，AI 接管运维 / AIMA灵机: One command. AI takes over ops."
    Refresh-WindowTitle
}

function Refresh-WindowTitle {
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI) {
            $Host.UI.RawUI.WindowTitle = $script:UxWindowTitle
        }
    } catch { }
}

function Format-Usd {
    param([object]$Value)

    $number = 0.0
    if ($null -ne $Value -and "$Value" -ne "") {
        try { $number = [double]$Value } catch { $number = 0.0 }
    }
    return '$' + ('{0:N2}' -f $number)
}

function Format-TaskBudgetUsedLine {
    param([object]$Used, [object]$Total)

    if ($script:DisplayLanguage -eq "zh_cn") { return "已用 $Used / 总量 $Total" }
    return "$Used / $Total used"
}

function Format-TaskBudgetRemainingLine {
    param([object]$Remaining, [object]$Total)

    if ($script:DisplayLanguage -eq "zh_cn") { return "剩余 $Remaining / 总量 $Total" }
    return "$Remaining / $Total remaining"
}

function Format-AmountBudgetUsedLine {
    param([object]$Spent, [object]$Total)

    if ($script:DisplayLanguage -eq "zh_cn") { return "已花 $(Format-Usd $Spent) / 总额 $(Format-Usd $Total)" }
    return "$(Format-Usd $Spent) / $(Format-Usd $Total) used"
}

function Format-AmountBudgetRemainingLine {
    param([object]$Remaining, [object]$Total)

    if ($script:DisplayLanguage -eq "zh_cn") { return "剩余 $(Format-Usd $Remaining) / 总额 $(Format-Usd $Total)" }
    return "$(Format-Usd $Remaining) / $(Format-Usd $Total) remaining"
}

function Sync-BudgetSnapshotFromBudgetObject {
    param([object]$Budget)

    if ($null -eq $Budget) { return }
    $script:DeviceMaxTasks = $Budget.max_tasks
    $script:DeviceUsedTasks = $Budget.used_tasks
    $script:DeviceBudgetUsd = $Budget.budget_usd
    $script:DeviceSpentUsd = $Budget.spent_usd
}

function Show-ConnectedSummary {
    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $script:UxBrandName" -ForegroundColor White
    Write-Host "  $script:UxBrandSlogan" -ForegroundColor DarkGray
    Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  ● $(Get-LangText '设备已连接!' 'Device linked!')" -ForegroundColor Green
    Write-Host "    $(Get-LangText '设备 ID' 'Device ID'): $script:DeviceId" -ForegroundColor Gray
    Write-Host "    $(Get-LangText '任务额度' 'Task budget'): $(Format-TaskBudgetUsedLine -Used $script:DeviceUsedTasks -Total $script:DeviceMaxTasks)" -ForegroundColor Gray
    Write-Host "    $(Get-LangText '金额额度' 'Amount budget'): $(Format-AmountBudgetUsedLine -Spent $script:DeviceSpentUsd -Total $script:DeviceBudgetUsd)" -ForegroundColor Gray
    if ($script:ReferralCode) {
        Write-Host "    $(Get-LangText '你的推荐码' 'Your referral code'): $script:ReferralCode" -ForegroundColor Yellow
    }
    Write-Host "    $(Get-LangText '凭证已保存到 ~/.aima-device-state' 'Credentials saved to ~/.aima-device-state')" -ForegroundColor Gray
    Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "    $(Get-LangText '后台已就绪。你现在可以直接下达任务。' 'Background session is ready. You can give AIMA a task now.')" -ForegroundColor Gray
    Write-Host "    $(Get-LangText "$($script:TaskCancelHotkeyLabel) 取消当前任务 · $($script:BindConsoleHotkeyLabel) 绑定控制台" "$($script:TaskCancelHotkeyLabel) cancel current task · $($script:BindConsoleHotkeyLabel) bind Console")" -ForegroundColor Gray
    Write-Host "    $(Get-LangText "$($script:DeviceDisconnectHotkeyLabel) 断开设备 · Ctrl+C 退出前台" "$($script:DeviceDisconnectHotkeyLabel) disconnect device · Ctrl+C exit foreground UI")" -ForegroundColor Gray
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}

function Show-SecuritySummary {
    Write-Host ""
    Write-Host "  $(Get-LangText '安全概览' 'Security profile')" -ForegroundColor White
    if ($BaseUrl -match '^https://') {
        Write-Host "    ✓ $(Get-LangText '链路已加密（HTTPS）' 'Connection: HTTPS encrypted')" -ForegroundColor Green
    } else {
        Write-Host "    ! $(Get-LangText '链路未加密，仅 HTTP 传输' 'Connection: HTTP only, not encrypted')" -ForegroundColor Yellow
    }
    Write-Host "    ✓ $(Get-LangText 'AIMA 已获权在当前终端执行指令' 'AIMA can run commands in this terminal')" -ForegroundColor Green
    Write-Host "    ✓ $(Get-LangText '高风险操作需管理员审批' 'High-risk commands require admin approval')" -ForegroundColor Green
    Write-Host "    ✓ $(Get-LangText '任务运行中可随时中断' 'You can interrupt running tasks at any time')" -ForegroundColor Green
    Write-Host "    ✓ $(Get-LangText 'AIMA 不会强制锁死当前终端' 'AIMA will not permanently lock this terminal')" -ForegroundColor Green
}

# ── aima shortcut ─────────────────────────────────────────────
$script:AimaShortcutDir = Join-Path $env:USERPROFILE ".local\bin"
$script:AimaShortcutPath = Join-Path $script:AimaShortcutDir "aima.cmd"

function Test-AimaShortcutInstalled {
    if (Test-Path -LiteralPath $script:AimaShortcutPath) { return (Test-AimaShortcutCurrent) }
    if (Get-Command aima -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Test-AimaShortcutCurrent {
    if (-not (Test-Path -LiteralPath $script:AimaShortcutPath)) { return $false }
    $content = Get-Content -LiteralPath $script:AimaShortcutPath -Raw -Encoding ascii -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    return $content.Contains("if ($u -match '/api/v1$')") -and $content.Contains("irm ($u + '/go')")
}

function Install-AimaShortcut {
    New-Item -ItemType Directory -Force -Path $script:AimaShortcutDir | Out-Null

    $cmdContent = @"
@echo off
for /f "tokens=1,* delims==" %%a in ('findstr /b "PLATFORM_URL=" "%USERPROFILE%\.aima-device-state"') do set "AIMA_URL=%%b"
if not defined AIMA_URL (
    echo AIMA: No saved device state. Please run the original setup command first.
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='%AIMA_URL%'.TrimEnd('/'); if ($u -match '/api/v1$') { $u = $u.Substring(0, $u.Length - 7) }; iex (irm ($u + '/go'))"
"@
    Set-Content -LiteralPath $script:AimaShortcutPath -Value $cmdContent -Encoding ascii

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and ($userPath -split ';' | Where-Object { $_ -eq $script:AimaShortcutDir })) {
        return
    }
    $newPath = if ($userPath) { "$script:AimaShortcutDir;$userPath" } else { $script:AimaShortcutDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

function Ensure-AimaShortcutCurrent {
    if (-not (Test-Path -LiteralPath $script:AimaShortcutPath)) { return }
    if (Test-AimaShortcutCurrent) { return }
    try {
        Install-AimaShortcut
        Write-Host "  ✓ $(Get-LangText '已更新旧版 aima 快捷命令。重新输入 aima 即可使用。' 'Updated the existing aima shortcut. Run aima again to use it.')" -ForegroundColor Green
    } catch {
        Write-Host "  ! $(Get-LangText '旧版快捷命令更新失败，不影响当前连接。' 'Existing shortcut upgrade failed; current connection is unaffected.')" -ForegroundColor Yellow
    }
}

function Prompt-AimaShortcut {
    if ($script:RunAsOwner) { return }
    if (Test-Path -LiteralPath $script:AimaShortcutPath) {
        Ensure-AimaShortcutCurrent
        return
    }
    if (Get-Command aima -ErrorAction SilentlyContinue) { return }

    Write-Host ""
    Write-Host "  $(Get-LangText '是否添加 aima 快捷命令？之后只需输入 aima 即可重新连接。' 'Add aima shortcut? Then just type aima to reconnect.')" -ForegroundColor White
    $answer = Read-Host "  [Y/n]"
    $answer = $answer.Trim()
    if ($answer -ne 'n' -and $answer -ne 'N') {
        try {
            Install-AimaShortcut
            Write-Host "  ✓ $(Get-LangText '已添加。打开新终端后输入 aima 即可启动。' 'Done. Open a new terminal and type aima to start.')" -ForegroundColor Green
        } catch {
            Write-Host "  ! $(Get-LangText '快捷命令安装失败，不影响正常使用。' 'Shortcut installation failed; this does not affect normal usage.')" -ForegroundColor Yellow
        }
    }
}

function Show-AttachedBanner {
    Refresh-WindowTitle
    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $script:UxBrandName · $script:UxBrandSlogan" -ForegroundColor White
    Write-Host "  $(Get-LangText '你现在看到的是前台观察界面。' 'This is the foreground observer UI.')" -ForegroundColor Gray
    Write-Host "  $(Get-LangText '设备会继续在后台保持连接。' 'The device stays connected in the background.')" -ForegroundColor Gray
    Write-Host "  $(Get-LangText "$($script:TaskCancelHotkeyLabel) 取消当前任务 · $($script:BindConsoleHotkeyLabel) 绑定控制台" "$($script:TaskCancelHotkeyLabel) cancel current task · $($script:BindConsoleHotkeyLabel) bind Console")" -ForegroundColor Gray
    Write-Host "  $(Get-LangText "$($script:DeviceDisconnectHotkeyLabel) 断开设备 · Ctrl+C 退出前台" "$($script:DeviceDisconnectHotkeyLabel) disconnect device · Ctrl+C exit foreground UI")" -ForegroundColor Gray
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}

function Prompt-LanguageSelection {
    Write-Host ""
    Write-Host "  选择显示语言 / Select display language:" -ForegroundColor White
    Write-Host "  1. 中文" -ForegroundColor Cyan
    Write-Host "  2. English" -ForegroundColor Cyan
    $answer = Read-Host "  > "
    $answer = $answer.Trim()
    if ($answer -match '^(2|en|EN|english|English|ENGLISH)$') {
        $script:DisplayLanguage = "en_us"
    } else {
        $script:DisplayLanguage = "zh_cn"
    }
    Save-DeviceState
    Reload-UxStrings
    # Sync to platform
    if ($script:DeviceId -and $script:DeviceToken) {
        try {
            Invoke-RestMethod -Method Post `
                -Uri "$BaseUrl/devices/$script:DeviceId/language" `
                -Headers (Get-Headers) `
                -ContentType "application/json" `
                -Body "{`"display_language`":`"$script:DisplayLanguage`"}" `
                -TimeoutSec 5 | Out-Null
        } catch { }
    }
}

function Get-GuidedFlowText {
    param(
        [string]$FlowKey,
        [string]$Field,
        [string]$Fallback = ""
    )

    return Get-UxText -Path "blocks.task_menu.context.guided_flows.$FlowKey.$Field.text" -Fallback $Fallback
}

function Get-GuidedFlowStepText {
    param(
        [string]$FlowKey,
        [int]$Index,
        [string]$Field,
        [string]$Fallback = ""
    )

    return Get-UxText -Path "blocks.task_menu.context.guided_flows.$FlowKey.steps.$Index.$Field.text" -Fallback $Fallback
}

function Build-GuidedTaskRequest {
    param([string]$FlowKey)

    $script:GuidedTaskPrimaryAnswer = $null
    $intro = Get-GuidedFlowTextLang -FlowKey $FlowKey -Field "summary_intro"
    if (-not $intro) {
        return $null
    }

    $missingAnswer = Get-UxTextLang -Path "blocks.task_menu.context.guided_missing_answer" -Fallback "未说明 / Not provided"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($intro) | Out-Null

    for ($index = 0; ; $index++) {
        $prompt = Get-GuidedFlowStepTextLang -FlowKey $FlowKey -Index $index -Field "prompt"
        if (-not $prompt) {
            break
        }

        $summaryLabel = Get-GuidedFlowStepTextLang -FlowKey $FlowKey -Index $index -Field "summary_label" -Fallback ("Step {0}" -f ($index + 1))
        $defaultAnswer = Get-GuidedFlowStepTextLang -FlowKey $FlowKey -Index $index -Field "default_answer"
        Write-Host ""
        Write-Host "  $prompt" -ForegroundColor Cyan
        $guidedInput = Read-ConsoleLine -Prompt "  > " -AllowDisconnectHotkey $true
        switch ($guidedInput.action) {
            "exit_ui" {
                $script:UiExitRequested = $true
                return "__exit_ui__"
            }
            "disconnect" {
                Request-ExplicitDisconnect
                return "__disconnect__"
            }
            "unavailable" {
                return $null
            }
        }

        $answer = [string]$guidedInput.value
        if (-not $answer) {
            if ($defaultAnswer) {
                $answer = $defaultAnswer
            } else {
                $answer = $missingAnswer
            }
        }
        if (-not $script:GuidedTaskPrimaryAnswer) {
            $script:GuidedTaskPrimaryAnswer = $answer
        }
        $lines.Add("- ${summaryLabel}: $answer") | Out-Null
    }

    $outro = Get-GuidedFlowTextLang -FlowKey $FlowKey -Field "summary_outro"
    if ($outro) {
        $lines.Add($outro) | Out-Null
    }
    return ($lines -join [Environment]::NewLine)
}

function New-TaskRequestBody {
    param(
        [string]$Description,
        [string]$Mode = "",
        [string]$UserRequest = "",
        [string]$Renderer = "",
        [string]$TaskTypeHint = "",
        [string]$SoftwareHint = "",
        [string]$ProblemHint = "",
        [string]$TargetHint = "",
        [string]$ErrorMessageHint = ""
    )

    $payload = [ordered]@{ description = $Description }
    $intake = [ordered]@{}
    if ($Mode) { $intake.mode = $Mode }
    if ($UserRequest) { $intake.user_request = $UserRequest }
    if ($SoftwareHint) { $intake.software_hint = $SoftwareHint }
    if ($ProblemHint) { $intake.problem_hint = $ProblemHint }
    if ($Renderer) { $intake.renderer = $Renderer }
    if ($intake.Count -gt 0) {
        $payload.intake = $intake
    }

    $experienceSearch = [ordered]@{}
    if ($TaskTypeHint) { $experienceSearch.task_type_hint = $TaskTypeHint }
    if ($TargetHint) { $experienceSearch.target_hint = $TargetHint }
    if ($ErrorMessageHint) { $experienceSearch.error_message_hint = $ErrorMessageHint }
    if ($experienceSearch.Count -gt 0) {
        $payload.experience_search = $experienceSearch
    }

    return ($payload | ConvertTo-Json -Compress -Depth 5)
}

function Normalize-TargetHint {
    param([string]$Value)
    if (-not $Value) {
        return ""
    }

    $cleaned = [regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9._+-]+', '_').Trim('._-')
    if ($cleaned.Length -gt 120) {
        return $cleaned.Substring(0, 120)
    }
    return $cleaned
}

function Test-SoftwareHintIgnored {
    param([string]$Value)
    switch ($Value) {
        "" { return $true }
        "aima" { return $true }
        "api" { return $true }
        "assistant" { return $true }
        "check" { return $true }
        "debug" { return $true }
        "deploy" { return $true }
        "diagnose" { return $true }
        "fix" { return $true }
        "for" { return $true }
        "from" { return $true }
        "help" { return $true }
        "install" { return $true }
        "issue" { return $true }
        "it" { return $true }
        "its" { return $true }
        "just" { return $true }
        "latest" { return $true }
        "machine" { return $true }
        "me" { return $true }
        "my" { return $true }
        "need" { return $true }
        "on" { return $true }
        "our" { return $true }
        "please" { return $true }
        "problem" { return $true }
        "repair" { return $true }
        "run" { return $true }
        "setup" { return $true }
        "system" { return $true }
        "task" { return $true }
        "that" { return $true }
        "the" { return $true }
        "their" { return $true }
        "these" { return $true }
        "this" { return $true }
        "those" { return $true }
        "to" { return $true }
        "use" { return $true }
        "using" { return $true }
        "version" { return $true }
        "want" { return $true }
        "we" { return $true }
        "with" { return $true }
        "you" { return $true }
        "your" { return $true }
        default { return $false }
    }
}

function Get-SoftwareHintFromText {
    param([string]$Text)
    if (-not $Text) {
        return ""
    }

    $candidate = ""
    $lower = $Text.ToLowerInvariant()
    if ($lower -match '(install|setup|deploy|upgrade|repair|fix|check|debug|troubleshoot|diagnose)\s+([a-z][a-z0-9._+-]{1,63})') {
        $candidate = $Matches[2]
    } elseif ($Text -match '(安装|装|配置|部署|升级|修复|修一下|检查|排查|诊断)\s*([A-Za-z][A-Za-z0-9._+-]{1,63})') {
        $candidate = $Matches[2]
    } elseif ($Text -match '^[^A-Za-z]*([A-Za-z][A-Za-z0-9._+-]{1,63})') {
        $candidate = $Matches[1]
    }

    $candidate = Normalize-TargetHint -Value $candidate
    if (Test-SoftwareHintIgnored -Value $candidate) {
        return ""
    }
    return $candidate
}

function Get-TaskTypeHintFromText {
    param([string]$Text)
    if (-not $Text) {
        return "general_ops"
    }

    $lower = $Text.ToLowerInvariant()
    if ($lower -match '\b(install|setup|deploy|upgrade)\b') {
        return "software_install"
    }
    if ($lower -match '\b(repair|fix|check|debug|troubleshoot|diagnose)\b') {
        return "software_repair"
    }
    if ($Text -match '安装|配置|部署|升级') {
        return "software_install"
    }
    if ($Text -match '修复|检查|排查|诊断|升级一下|修一下') {
        return "software_repair"
    }
    return "general_ops"
}

function Prompt-InviteCode {
    param([string]$Reason = "")
    if ([System.Console]::IsInputRedirected) {
        if ($Reason) {
            throw "$Reason`n$script:UxInviteRequiredRedirected"
        }
        throw $script:UxInviteRequiredRedirected
    }
    if ($Reason) {
        Write-Host ""
        Write-Host "  $Reason" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  $script:UxInvitePrompt"
    $script:InviteCode = Read-Host "  > "
    if (-not $script:InviteCode) {
        throw $script:UxInviteRequired
    }
}

function Prompt-RecoveryCode {
    param([string]$Reason = "")
    $requiredMessage = Get-LangText `
        '这台旧设备还没有绑定 device manager，仍需恢复码才能继续。' `
        'This existing device is not yet bound to a device manager, so a recovery code is still required.'
    $redirectedMessage = Get-LangText `
        '当前终端不可交互。请在交互式 PowerShell 中重新运行 /go 并输入恢复码。' `
        'This terminal is non-interactive. Rerun /go in an interactive PowerShell session and enter the recovery code.'
    if ([System.Console]::IsInputRedirected) {
        if ($Reason) {
            throw "$Reason`n$redirectedMessage"
        }
        throw $redirectedMessage
    }
    if ($Reason) {
        Write-Host ""
        Write-Host "  $Reason" -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "  $requiredMessage" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  $(Get-LangText '请输入恢复码:' 'Please enter the recovery code:')"
    $script:RecoveryCode = Read-Host "  > "
    if (-not $script:RecoveryCode) {
        throw (Get-LangText '需要恢复码才能继续。' 'Recovery code required to continue.')
    }
}

function Save-DeviceState {
    $content = "DEVICE_ID=$script:DeviceId`nDEVICE_TOKEN=$script:DeviceToken`nRECOVERY_CODE=$script:RecoveryCode`nLAST_NOTIFIED_TASK_ID=$script:LastNotifiedTaskId`nPLATFORM_URL=$BaseUrl`nDISPLAY_LANGUAGE=$script:DisplayLanguage`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($StateFile, $content, $utf8NoBom)
    Protect-StateFilePermissions -Path $StateFile
}

function Protect-StateFilePermissions {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $currentIdentity -or $null -eq $currentIdentity.User) {
            return
        }

        $fileInfo = New-Object System.IO.FileInfo($Path)
        $sections = [System.Security.AccessControl.AccessControlSections]::Access
        $acl = $fileInfo.GetAccessControl($sections)
        $acl.SetAccessRuleProtection($true, $false)

        foreach ($existingRule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            [void]$acl.RemoveAccessRuleAll($existingRule)
        }

        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentIdentity.User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($userRule)
        $fileInfo.SetAccessControl($acl)
    } catch {
        # Ignore ACL hardening failures; device state still exists and retry loops should stay quiet.
    }
}

function Test-RetryableFileAccessError {
    param([Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ($null -eq $ErrorRecord.Exception) {
        return $false
    }
    return (
        $ErrorRecord.Exception -is [System.IO.IOException] -or
        $ErrorRecord.Exception -is [System.UnauthorizedAccessException]
    )
}

function Write-TextFileWithRetry {
    param(
        [string]$Path,
        [string]$Content,
        [System.Text.Encoding]$Encoding,
        [switch]$Append,
        [int]$Attempts = 5,
        [int]$DelayMilliseconds = 100,
        [switch]$IgnoreFailure
    )

    Ensure-RuntimeDirectory
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            if ($Append) {
                [System.IO.File]::AppendAllText($Path, $Content, $Encoding)
            } else {
                [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
            }
            Protect-StateFilePermissions -Path $Path
            return $true
        } catch {
            if ((-not (Test-RetryableFileAccessError -ErrorRecord $_)) -or $attempt -ge ($Attempts - 1)) {
                if ($IgnoreFailure) {
                    return $false
                }
                throw
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    if ($IgnoreFailure) {
        return $false
    }
    return $false
}

function Read-TextFileWithRetry {
    param(
        [string]$Path,
        [System.Text.Encoding]$Encoding,
        [int]$Attempts = 5,
        [int]$DelayMilliseconds = 100
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            return [System.IO.File]::ReadAllText($Path, $Encoding)
        } catch {
            if ((-not (Test-RetryableFileAccessError -ErrorRecord $_)) -or $attempt -ge ($Attempts - 1)) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    return $null
}

function Ensure-RuntimeDirectory {
    if (-not (Test-Path -LiteralPath $RuntimeDir)) {
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    }
    Protect-StateFilePermissions -Path $RuntimeDir
}

function Ensure-CommandExecutionRoot {
    Ensure-RuntimeDirectory
    if (-not (Test-Path -LiteralPath $script:CommandExecutionRoot)) {
        New-Item -ItemType Directory -Path $script:CommandExecutionRoot -Force | Out-Null
    }
    Protect-StateFilePermissions -Path $script:CommandExecutionRoot
}

function Get-FileSizeBytes {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    try {
        return [int64](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    } catch {
        return 0
    }
}

function New-CommandExecutionSandbox {
    param(
        [string]$TaskId,
        [string]$CommandId,
        [string]$CommandText,
        [string]$CommandIntent = ""
    )

    Ensure-CommandExecutionRoot
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $resolvedTaskId = if ($TaskId) { $TaskId } else { "task-unknown" }
    $resolvedCommandId = if ($CommandId) { $CommandId } else { [System.Guid]::NewGuid().ToString("N") }
    $safeTaskId = ($resolvedTaskId -replace '[^A-Za-z0-9._-]', '_')
    $safeCommandId = ($resolvedCommandId -replace '[^A-Za-z0-9._-]', '_')
    $taskDir = Join-Path $script:CommandExecutionRoot $safeTaskId
    $artifactDir = Join-Path $taskDir $safeCommandId
    $workDir = Join-Path $artifactDir "workdir"
    $commandPath = Join-Path $artifactDir "command.ps1"
    $runnerPath = Join-Path $artifactDir "runner.cmd"
    $stdoutPath = Join-Path $artifactDir "stdout.log"
    $stderrPath = Join-Path $artifactDir "stderr.log"
    $journalPath = Join-Path $artifactDir "journal.json"

    foreach ($path in @($taskDir, $artifactDir, $workDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        Protect-StateFilePermissions -Path $path
    }

    [void](Write-TextFileWithRetry -Path $commandPath -Content $CommandText -Encoding $utf8NoBom)
    [void](Write-TextFileWithRetry -Path $runnerPath -Content (@"
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0command.ps1" < NUL > "%~dp0stdout.log" 2> "%~dp0stderr.log"
exit /b %ERRORLEVEL%
"@) -Encoding $utf8NoBom)
    Protect-StateFilePermissions -Path $commandPath
    Protect-StateFilePermissions -Path $runnerPath

    return [pscustomobject]@{
        TaskId = $resolvedTaskId
        CommandId = $resolvedCommandId
        Intent = $CommandIntent
        ArtifactDir = [System.IO.Path]::GetFullPath($artifactDir)
        WorkDir = [System.IO.Path]::GetFullPath($workDir)
        CommandPath = [System.IO.Path]::GetFullPath($commandPath)
        RunnerPath = [System.IO.Path]::GetFullPath($runnerPath)
        StdoutPath = [System.IO.Path]::GetFullPath($stdoutPath)
        StderrPath = [System.IO.Path]::GetFullPath($stderrPath)
        JournalPath = [System.IO.Path]::GetFullPath($journalPath)
    }
}

function Write-CommandExecutionJournal {
    param(
        [object]$Sandbox,
        [string]$Status,
        [int]$ExitCode = 0,
        [int]$ProcessId = 0,
        [int64]$StartedAt = 0,
        [int64]$CompletedAt = 0
    )

    if (-not $Sandbox -or -not $Sandbox.JournalPath) {
        return
    }

    $payload = @{
        task_id = $Sandbox.TaskId
        command_id = $Sandbox.CommandId
        intent = $Sandbox.Intent
        status = $Status
        artifact_dir = $Sandbox.ArtifactDir
        work_dir = $Sandbox.WorkDir
        command_path = $Sandbox.CommandPath
        runner_path = $Sandbox.RunnerPath
        stdout_log_path = $Sandbox.StdoutPath
        stderr_log_path = $Sandbox.StderrPath
        stdout_log_bytes = (Get-FileSizeBytes -Path $Sandbox.StdoutPath)
        stderr_log_bytes = (Get-FileSizeBytes -Path $Sandbox.StderrPath)
        stdout_tail = (Get-FileTailText -Path $Sandbox.StdoutPath -MaxChars $script:CommandResultTailMaxChars)
        stderr_tail = (Get-FileTailText -Path $Sandbox.StderrPath -MaxChars $script:CommandResultTailMaxChars)
        updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    if ($StartedAt -gt 0) {
        $payload["started_at"] = $StartedAt
    }
    if ($CompletedAt -gt 0) {
        $payload["completed_at"] = $CompletedAt
    }
    if ($ProcessId -gt 0) {
        $payload["pid"] = $ProcessId
    }
    if ($Status -in @("completed", "failed", "timed_out", "cancelled")) {
        $payload["exit_code"] = $ExitCode
    }

    Write-JsonFile -Path $Sandbox.JournalPath -Payload $payload
}

function Get-JsonFileObject {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    # Heartbeat/status files are updated concurrently by launcher and owner.
    # Retry through short-lived Windows file locks and partial writes before
    # classifying the background session as unhealthy.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $text = Read-TextFileWithRetry -Path $Path -Encoding ([System.Text.Encoding]::UTF8)
            if (-not $text) {
                return $null
            }
            return $text | ConvertFrom-Json -ErrorAction Stop
        } catch {
            if ($attempt -ge 4) {
                return $null
            }
            Start-Sleep -Milliseconds 100
        }
    }

    return $null
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Payload
    )

    Ensure-RuntimeDirectory
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $Payload | ConvertTo-Json -Compress -Depth 5
    [void](Write-TextFileWithRetry -Path $Path -Content $json -Encoding $utf8NoBom)
}

function Write-OwnerLogLine {
    param(
        [string]$Level = "INFO",
        [string]$Message = ""
    )

    if (-not $Message) {
        return
    }

    Ensure-RuntimeDirectory
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $line = "{0} [{1}] {2}`n" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), $Level, $Message
    # Keep launcher-side diagnostics out of owner stdout redirection to avoid
    # Windows file-share collisions when the owner is running in the background.
    [void](Write-TextFileWithRetry -Path $script:LauncherLogFile -Content $line -Encoding $utf8NoBom -Append -IgnoreFailure)
}

function Clear-RuntimeEphemeralFiles {
    foreach ($path in @(
        $script:OwnerHeartbeatFile,
        $script:SessionStatusFile,
        $script:PendingInteractionFile,
        $script:InteractionAnswerFile,
        $script:TaskCompletionFile,
        $script:DisconnectRequestFile
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Clear-TaskRuntimeState {
    foreach ($path in @(
        $script:SessionStatusFile,
        $script:PendingInteractionFile,
        $script:InteractionAnswerFile,
        $script:TaskCompletionFile
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Reset-AttachRuntimeCache {
    $script:AttachLastStatusKey = $null
    $script:AttachLastInteractionId = $null
    $script:AttachDeferredInteractionId = $null
    $script:AttachInteractionRetryAfter = [int64]0
    $script:AttachLastCompletionId = $null
}

function Clear-RuntimeOwnerBootstrapFiles {
    foreach ($path in @(
        $script:OwnerHeartbeatFile,
        $script:PendingInteractionFile,
        $script:InteractionAnswerFile,
        $script:SessionStatusFile,
        $script:TaskCompletionFile,
        $script:DisconnectRequestFile
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Write-SessionStatus {
    param(
        [string]$Phase,
        [string]$Level,
        [string]$Message,
        [string]$ActiveTaskId = $script:ActiveTaskId
    )

    if (-not $script:RunAsOwner) {
        return
    }

    Write-JsonFile -Path $script:SessionStatusFile -Payload @{
        phase = $Phase
        level = $Level
        message = $Message
        active_task_id = $ActiveTaskId
        updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Write-OwnerHeartbeat {
    param(
        [string]$Phase = "idle",
        [string]$ActiveTaskId = $script:ActiveTaskId,
        [string]$CommandId = ""
    )

    if (-not $script:RunAsOwner) {
        return
    }

    Write-JsonFile -Path $script:OwnerHeartbeatFile -Payload @{
        pid = [System.Diagnostics.Process]::GetCurrentProcess().Id
        device_id = $script:DeviceId
        phase = $Phase
        active_task_id = $ActiveTaskId
        command_id = $CommandId
        updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Write-PendingInteractionFile {
    param(
        [string]$InteractionId,
        [string]$Question,
        [string]$InteractionType,
        [string]$InteractionLevel,
        [string]$InteractionPhase,
        [string]$DisplayQuestion = "",
        [string]$ActiveTaskId = $script:ActiveTaskId
    )

    Write-JsonFile -Path $script:PendingInteractionFile -Payload @{
        interaction_id = $InteractionId
        question = $Question
        interaction_type = $InteractionType
        interaction_level = $InteractionLevel
        interaction_phase = $InteractionPhase
        display_question = $DisplayQuestion
        active_task_id = $ActiveTaskId
        updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Clear-PendingInteractionFile {
    Remove-Item -LiteralPath $script:PendingInteractionFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:InteractionAnswerFile -Force -ErrorAction SilentlyContinue
}

function Write-InteractionAnswerFile {
    param(
        [string]$InteractionId,
        [string]$Answer
    )

    Write-JsonFile -Path $script:InteractionAnswerFile -Payload @{
        interaction_id = $InteractionId
        answer = $Answer
        updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Write-TaskCompletionFile {
    param(
        [string]$TaskId,
        [string]$TaskStatus,
        [object]$BudgetTasksRemaining,
        [object]$BudgetTasksTotal,
        [object]$BudgetUsdRemaining,
        [object]$BudgetUsdTotal,
        [string]$ReferralCode,
        [string]$ShareText,
        [string]$TaskMessage = ""
    )

    Write-JsonFile -Path $script:TaskCompletionFile -Payload @{
        task_id = $TaskId
        task_status = $TaskStatus
        budget_tasks_remaining = $BudgetTasksRemaining
        budget_tasks_total = $BudgetTasksTotal
        budget_usd_remaining = $BudgetUsdRemaining
        budget_usd_total = $BudgetUsdTotal
        referral_code = $ReferralCode
        share_text = $ShareText
        task_message = $TaskMessage
        updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Get-OwnerPid {
    if (-not (Test-Path -LiteralPath $script:OwnerPidFile)) {
        return $null
    }

    try {
        $pidText = (Get-Content -LiteralPath $script:OwnerPidFile -Raw -ErrorAction Stop).Trim()
        if (-not $pidText) {
            return $null
        }
        return [int]$pidText
    } catch {
        return $null
    }
}

function Get-OwnerTaskName {
    if ($script:DeviceId) {
        return "AIMA-DeviceOwner-$($script:DeviceId)"
    }
    return "AIMA-DeviceOwner"
}

function Invoke-CmdProcess {
    param([string]$CommandLine)

    $process = Start-Process -FilePath "cmd.exe" `
        -ArgumentList @("/d", "/c", $CommandLine) `
        -PassThru `
        -Wait `
        -WindowStyle Hidden
    return [int]$process.ExitCode
}

function Test-OwnerRunning {
    $ownerPid = Get-OwnerPid
    if (-not $ownerPid) {
        return $false
    }
    return [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
}

function Get-OwnerHealthDetail {
    if (-not (Test-OwnerRunning)) {
        return "owner pid missing or process not running"
    }

    $heartbeat = Get-JsonFileObject -Path $script:OwnerHeartbeatFile
    if (-not $heartbeat -or $null -eq $heartbeat.updated_at) {
        if (-not $heartbeat) {
            return "owner heartbeat file missing"
        }
        return "owner heartbeat missing updated_at"
    }

    $phase = if ($heartbeat.phase) { [string]$heartbeat.phase } else { "unknown" }
    $activeTaskId = if ($heartbeat.active_task_id) { [string]$heartbeat.active_task_id } else { "-" }
    $commandId = if ($heartbeat.command_id) { [string]$heartbeat.command_id } else { "-" }

    try {
        $updatedAt = [int64]$heartbeat.updated_at
    } catch {
        return "owner heartbeat missing updated_at (phase=$phase, active_task=$activeTaskId, command_id=$commandId)"
    }

    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $updatedAt
    if ($age -lt 0) {
        $age = 0
    }
    if ($age -gt $script:OwnerHeartbeatStaleSeconds) {
        return "owner heartbeat stale (age=${age}s, phase=$phase, active_task=$activeTaskId, command_id=$commandId)"
    }

    if ($script:DeviceId -and $heartbeat.device_id -and [string]$heartbeat.device_id -ne $script:DeviceId) {
        return "owner heartbeat device mismatch (heartbeat=$([string]$heartbeat.device_id), current=$script:DeviceId)"
    }

    return $null
}

function Get-OwnerActiveTaskId {
    $heartbeat = Get-JsonFileObject -Path $script:OwnerHeartbeatFile
    if ($heartbeat -and $heartbeat.active_task_id) {
        return [string]$heartbeat.active_task_id
    }
    return $null
}

function Test-OwnerHealthy {
    return -not [bool](Get-OwnerHealthDetail)
}

function Remove-OwnerScheduledTask {
    if (-not (Get-Command schtasks.exe -ErrorAction SilentlyContinue)) {
        return
    }

    $taskName = Get-OwnerTaskName
    [void](Invoke-CmdProcess -CommandLine ('schtasks /Delete /TN "{0}" /F >nul 2>nul' -f $taskName))
}

function Get-LauncherScriptUrl {
    if ($BaseUrl -match '^(.*?)/api/v1/?$') {
        return "$($Matches[1])/go.ps1"
    }
    return "$BaseUrl/go.ps1"
}

function Install-OwnerScript {
    Ensure-RuntimeDirectory
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $scriptText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
        [System.IO.File]::WriteAllText($script:OwnerScriptPath, [string]$scriptText, $utf8WithBom)
    } else {
        Invoke-WebRequest -Uri (Get-LauncherScriptUrl) -UseBasicParsing -OutFile $script:OwnerScriptPath
    }
    Protect-StateFilePermissions -Path $script:OwnerScriptPath
}

function Wait-OwnerHealthy {
    param([int]$Attempts = 30, [int]$DelayMilliseconds = 500)

    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        if (Test-OwnerHealthy) {
            return $true
        }
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
    return $false
}

function Start-OwnerDetachedProcess {
    param([string]$PowerShellExe)

    try {
        Start-Process -FilePath $PowerShellExe `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $script:OwnerScriptPath,
                "--owner"
            ) `
            -WorkingDirectory $RuntimeDir `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:OwnerLogFile `
            -RedirectStandardError $script:OwnerErrorLogFile `
            -PassThru `
            -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Start-OwnerProcess {
    Ensure-RuntimeDirectory
    if (Test-OwnerHealthy) {
        return $true
    }
    if (Test-OwnerRunning) {
        Stop-OwnerProcess
    }

    Install-OwnerScript
    Clear-RuntimeOwnerBootstrapFiles
    Remove-Item -LiteralPath $script:OwnerPidFile -Force -ErrorAction SilentlyContinue
    Remove-OwnerScheduledTask

    $powershellExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $powershellExe) {
        $powershellExe = "powershell.exe"
    }

    if (Start-OwnerDetachedProcess -PowerShellExe $powershellExe) {
        if (Wait-OwnerHealthy) {
            return $true
        }
        if (Test-OwnerRunning) {
            Stop-OwnerProcess
        }
    }

    $taskName = Get-OwnerTaskName
    $startTime = (Get-Date).AddMinutes(1).ToString("HH:mm")
    $taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"' + $script:OwnerScriptPath + '\" --owner'

    if (Get-Command schtasks.exe -ErrorAction SilentlyContinue) {
        $createExit = Invoke-CmdProcess -CommandLine ('schtasks /Create /TN "{0}" /SC ONCE /ST {1} /TR "{2}" /F /RL LIMITED >nul 2>nul' -f $taskName, $startTime, $taskCommand)
        if ($createExit -eq 0) {
            $runExit = Invoke-CmdProcess -CommandLine ('schtasks /Run /TN "{0}" >nul 2>nul' -f $taskName)
            if ($runExit -eq 0) {
                if (Wait-OwnerHealthy) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Stop-OwnerProcess {
    $ownerPid = Get-OwnerPid
    if (-not $ownerPid) {
        Remove-OwnerScheduledTask
        return
    }

    Stop-ProcessTree -ProcessId $ownerPid
    Remove-Item -LiteralPath $script:OwnerPidFile -Force -ErrorAction SilentlyContinue
    Remove-OwnerScheduledTask
}

function Wait-OwnerShutdown {
    param([int]$TimeoutSeconds = 5)

    $maxAttempts = [Math]::Max(1, [int]($TimeoutSeconds * 5))
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        if (-not (Test-OwnerRunning)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Load-DeviceState {
    if (Test-Path $StateFile) {
        $lines = Get-Content -Path $StateFile -Encoding UTF8
        foreach ($line in $lines) {
            if ($line -match '^DEVICE_ID=(.*)$')      { $script:DeviceId = $Matches[1] }
            if ($line -match '^DEVICE_TOKEN=(.*)$')    { $script:DeviceToken = $Matches[1] }
            if ($line -match '^RECOVERY_CODE=(.*)$')   { $script:RecoveryCode = $Matches[1] }
            if ($line -match '^LAST_NOTIFIED_TASK_ID=(.*)$') { $script:LastNotifiedTaskId = $Matches[1] }
            if ($line -match '^DISPLAY_LANGUAGE=(.*)$') { $script:DisplayLanguage = $Matches[1] }
        }
        if ($script:DeviceId -and $script:DeviceToken) { return $true }
    }
    return $false
}

function Load-RecoveryCodeFromSavedState {
    if ($script:RecoveryCode) {
        return $false
    }

    $cliStateFile = Join-Path $env:USERPROFILE ".aima-cli\device-state.json"
    if (Test-Path $cliStateFile) {
        try {
            $cliState = Get-Content -LiteralPath $cliStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($cliState.recovery_code) {
                $script:RecoveryCode = [string]$cliState.recovery_code
            }
            if ($cliState.platform_url) {
                $preferredUrl = Select-PreferredPlatformUrl -CurrentUrl $BaseUrl -SavedUrl ([string]$cliState.platform_url)
                Set-Variable -Name BaseUrl -Scope Script -Value $preferredUrl
            }
        } catch { }
    }

    $candidateStateFiles = @(
        $StateFile,
        (Join-Path $env:USERPROFILE ".aima-device-entry-smoke\windows\.aima-device-state"),
        (Join-Path $env:USERPROFILE ".aima-device-entry-smoke\.aima-device-state")
    )
    foreach ($candidate in $candidateStateFiles) {
        if ($script:RecoveryCode) {
            break
        }
        if (-not (Test-Path $candidate)) {
            continue
        }
        try {
            Get-Content -LiteralPath $candidate -Encoding UTF8 | ForEach-Object {
                if ((-not $script:RecoveryCode) -and ($_ -match '^RECOVERY_CODE=(.*)$')) {
                    $script:RecoveryCode = $Matches[1]
                }
                if ($_ -match '^PLATFORM_URL=(.*)$') {
                    $preferredUrl = Select-PreferredPlatformUrl -CurrentUrl $BaseUrl -SavedUrl $Matches[1]
                    Set-Variable -Name BaseUrl -Scope Script -Value $preferredUrl
                }
            }
        } catch { }
    }

    if ((-not $script:RecoveryCode) -and (Test-Path (Join-Path $env:USERPROFILE ".aima-device-entry-smoke"))) {
        try {
            $fallbackState = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".aima-device-entry-smoke") -Filter ".aima-device-state" -File -Recurse -ErrorAction Stop |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($fallbackState) {
                Get-Content -LiteralPath $fallbackState.FullName -Encoding UTF8 | ForEach-Object {
                    if ((-not $script:RecoveryCode) -and ($_ -match '^RECOVERY_CODE=(.*)$')) {
                        $script:RecoveryCode = $Matches[1]
                    }
                    if ($_ -match '^PLATFORM_URL=(.*)$') {
                        $preferredUrl = Select-PreferredPlatformUrl -CurrentUrl $BaseUrl -SavedUrl $Matches[1]
                        Set-Variable -Name BaseUrl -Scope Script -Value $preferredUrl
                    }
                }
            }
        } catch { }
    }

    return [bool]$script:RecoveryCode
}

function Refresh-DeviceStateFromDisk {
    $recoveryCode = $script:RecoveryCode
    $script:DeviceId = $null
    $script:DeviceToken = $null
    $script:LastNotifiedTaskId = $null
    [void](Load-DeviceState)
    if (-not $script:RecoveryCode) {
        $script:RecoveryCode = $recoveryCode
    }
}

function Invoke-DeviceApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [object]$Body = $null,
        [string]$ContentType = $null,
        [int]$TimeoutSec = 15
    )

    Refresh-DeviceStateFromDisk

    $invokeParams = @{
        Method = $Method
        Uri = $Uri
        Headers = (Get-Headers)
        TimeoutSec = $TimeoutSec
    }
    if ($ContentType) {
        $invokeParams["ContentType"] = $ContentType
    }
    if ($null -ne $Body) {
        $invokeParams["Body"] = $Body
    }

    try {
        return Invoke-RestMethod @invokeParams
    } catch {
        $statusCode = Get-HttpStatusCode $_
        if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
            Refresh-DeviceStateFromDisk
            $invokeParams["Headers"] = (Get-Headers)
            return Invoke-RestMethod @invokeParams
        }
        throw
    }
}

function Clear-DeviceState {
    $script:DeviceId = $null
    $script:DeviceToken = $null
    $script:LastNotifiedTaskId = $null
    $script:ActiveTaskId = $null
    $script:ConfirmedActiveTaskId = $null
    $script:LastVisibleActiveTaskId = $null
    $script:ActiveTaskLookupMisses = 0
    if ($script:RecoveryCode) {
        Save-DeviceState
    } else {
        Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-Offline {
    if ($script:DeviceId -and $script:DeviceToken) {
        try {
            Invoke-DeviceApi -Method Post -Uri "$BaseUrl/devices/$script:DeviceId/offline" -TimeoutSec 5 | Out-Null
        } catch { }
    }
}

function Get-ActiveTaskInfo {
    try {
        return Invoke-DeviceApi -Method Get `
            -Uri "$BaseUrl/devices/$script:DeviceId/active-task" `
            -TimeoutSec 10
    } catch {
        return $null
    }
}

function Adopt-ActiveTaskAfterSubmitFailure {
    param([string]$SubmittedDescription = "")

    $activeTask = Get-ActiveTaskInfo
    if (-not $activeTask -or $activeTask.has_active_task -ne $true -or -not $activeTask.task_id) {
        return $false
    }

    $script:ActiveTaskId = [string]$activeTask.task_id
    $script:ConfirmedActiveTaskId = $script:ActiveTaskId
    $script:LastVisibleActiveTaskId = $null
    $script:ActiveTaskLookupMisses = 0

    Write-Host "  $(Get-LangText '任务提交响应中断，已附着到当前任务' 'Task submit response was interrupted; attached to the current task'): $script:ActiveTaskId" -ForegroundColor Yellow
    if ($activeTask.target) {
        Write-Host "    $($activeTask.target)" -ForegroundColor DarkGray
    } elseif ($SubmittedDescription) {
        Write-Host "    $SubmittedDescription" -ForegroundColor DarkGray
    }
    return $true
}

function Cancel-ActiveTask {
    $activeTask = Get-ActiveTaskInfo
    $taskId = if ($script:ActiveTaskId) { $script:ActiveTaskId } elseif ($activeTask -and $activeTask.task_id) { $activeTask.task_id } else { $null }
    if (-not $taskId) {
        return $false
    }

    try {
        Invoke-DeviceApi -Method Post `
            -Uri "$BaseUrl/devices/$script:DeviceId/tasks/$taskId/cancel" `
            -TimeoutSec 10 | Out-Null
        $script:LastLocallyCancelledTaskId = [string]$taskId
        $script:ActiveTaskId = $null
        $script:ConfirmedActiveTaskId = $null
        $script:LastVisibleActiveTaskId = $null
        $script:ActiveTaskLookupMisses = 0
        $script:LocalCancelRequested = $true
        Clear-TaskRuntimeState
        Reset-AttachRuntimeCache
        Write-Host ""
        Write-Host "  $(Get-LangText '当前任务已取消' 'Current task cancelled')"
        return $true
    } catch {
        $sc = Get-HttpStatusCode $_
        $currentActiveTask = Get-ActiveTaskInfo
        $currentTaskId = if ($currentActiveTask -and $currentActiveTask.has_active_task -eq $true) {
            [string]$currentActiveTask.task_id
        } else {
            $null
        }
        if (-not $currentTaskId -or $currentTaskId -ne $taskId) {
            $script:LastLocallyCancelledTaskId = [string]$taskId
            $script:ActiveTaskId = $null
            $script:ConfirmedActiveTaskId = $null
            $script:LastVisibleActiveTaskId = $null
            $script:ActiveTaskLookupMisses = 0
            $script:LocalCancelRequested = $true
            Clear-TaskRuntimeState
            Reset-AttachRuntimeCache
            Write-Host ""
            Write-Host "  $(Get-LangText '当前任务已取消' 'Current task cancelled')"
            return $true
        }
        Write-Host ""
        Write-Host "  $(Get-LangText '取消任务失败' 'Failed to cancel current task') (HTTP $sc)"
        return $false
    }
}

function Get-PendingHotkeyAction {
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if (-not ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                continue
            }
            switch ($key.Key) {
                ([ConsoleKey]::B) { return "bind" }
                ([ConsoleKey]::K) { return "cancel" }
                ([ConsoleKey]::D) { return "disconnect" }
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Read-ConsoleLine {
    param(
        [string]$Prompt = "  > ",
        [string]$PromptColor = "",
        [bool]$AllowCancelHotkey = $false,
        [bool]$AllowDisconnectHotkey = $false,
        [bool]$AllowBindHotkey = $false
    )

    if ([System.Console]::IsInputRedirected) {
        return [pscustomobject]@{
            action = "unavailable"
            value = $null
        }
    }

    $builder = New-Object System.Text.StringBuilder
    if ($PromptColor) {
        Write-Host $Prompt -NoNewline -ForegroundColor $PromptColor
    } else {
        Write-Host $Prompt -NoNewline
    }
    while ($true) {
        $key = [Console]::ReadKey($true)
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $AllowCancelHotkey -and $key.Key -eq [ConsoleKey]::K) {
            Write-Host ""
            return [pscustomobject]@{
                action = "cancel"
                value = $null
            }
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::C) {
            Write-Host ""
            return [pscustomobject]@{
                action = "exit_ui"
                value = $null
            }
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $AllowDisconnectHotkey -and $key.Key -eq [ConsoleKey]::D) {
            Write-Host ""
            return [pscustomobject]@{
                action = "disconnect"
                value = $null
            }
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $AllowBindHotkey -and $key.Key -eq [ConsoleKey]::B) {
            Write-Host ""
            return [pscustomobject]@{
                action = "bind"
                value = $null
            }
        }

        switch ($key.Key) {
            ([ConsoleKey]::Enter) {
                Write-Host ""
                return [pscustomobject]@{
                    action = "submit"
                    value = $builder.ToString()
                }
            }
            ([ConsoleKey]::Backspace) {
                if ($builder.Length -gt 0) {
                    $builder.Length -= 1
                    Write-Host "`b `b" -NoNewline
                }
            }
            default {
                if (-not [char]::IsControl($key.KeyChar)) {
                    [void]$builder.Append($key.KeyChar)
                    Write-Host $key.KeyChar -NoNewline
                }
            }
        }
    }
}

function Read-ConsolePasteContinuation {
    param([int]$IdleWindowMs = 40)

    if ([System.Console]::IsInputRedirected) {
        return ""
    }

    $builder = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddMilliseconds($IdleWindowMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $consumed = $false
        try {
            while ([Console]::KeyAvailable) {
                $consumed = $true
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    ([ConsoleKey]::Enter) {
                        [void]$builder.Append("`n")
                    }
                    ([ConsoleKey]::Backspace) {
                        if ($builder.Length -gt 0) {
                            $builder.Length -= 1
                        }
                    }
                    default {
                        if (-not [char]::IsControl($key.KeyChar)) {
                            [void]$builder.Append($key.KeyChar)
                        }
                    }
                }
            }
        } catch {
            break
        }

        if ($consumed) {
            $deadline = [DateTime]::UtcNow.AddMilliseconds($IdleWindowMs)
            continue
        }

        Start-Sleep -Milliseconds 10
    }

    return $builder.ToString().TrimStart("`r", "`n")
}

function Show-DetachMessage {
    Write-Host ""
    Write-Host "  $(Get-LangText '已退出前台界面。' 'Detached from device session.')"
    Write-Host "  $(Get-LangText '设备会继续在后台保持连接，重新运行即可恢复界面。' 'The device stays connected in the background. Run again to reattach.')"
}

function Request-ExplicitDisconnect {
    $script:ExplicitDisconnectRequested = $true
    Ensure-RuntimeDirectory
    Set-Content -LiteralPath $script:DisconnectRequestFile -Value "" -Encoding ascii
    if (Test-OwnerRunning) {
        if (Wait-OwnerShutdown -TimeoutSeconds 5) {
            Clear-RuntimeEphemeralFiles
            Remove-Item -LiteralPath $script:OwnerPidFile -Force -ErrorAction SilentlyContinue
            Remove-OwnerScheduledTask
            Write-Host ""
            Write-Host "  $(Get-LangText '已断开连接。重新运行即可重连。' 'Disconnected. Run again to reconnect.')"
            return
        }
    }
    Stop-OwnerProcess
    Refresh-DeviceStateFromDisk
    Set-Offline
    Write-Host ""
    Write-Host "  $(Get-LangText '已断开连接。重新运行即可重连。' 'Disconnected. Run again to reconnect.')"
}

function Renew-Token {
    Write-OwnerHeartbeat -Phase "renewing"
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/devices/$script:DeviceId/renew-token" -Headers (Get-Headers)
        if ($response.token) {
            $script:DeviceToken = $response.token
            Save-DeviceState
        }
    } catch {
        $statusCode = Get-HttpStatusCode $_
        if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
            Write-Host "[AIMA] $(Get-LangText '设备凭据无效或已过期，正在退出。' 'Device token invalid or expired; exiting.')"
            Write-Host "[AIMA] $(Get-LangText '续签时凭据被拒绝，正在清理本地状态并停止。' 'Saved device credentials rejected during renewal; clearing local state and stopping.') (HTTP $statusCode)"
            Clear-DeviceState
            throw
        }
    }
}

function Submit-CommandResult {
    param(
        [string]$Body,
        [string]$CommandId = ""
    )
    $attempt = 0
    while ($true) {
        Write-OwnerHeartbeat -Phase "result_upload" -CommandId $CommandId
        try {
            $resultResponse = Invoke-WebRequest -Method Post `
                -Uri "$BaseUrl/devices/$script:DeviceId/result" `
                -Headers (Get-Headers) `
                -ContentType "application/json; charset=utf-8" `
                -UseBasicParsing `
                -TimeoutSec 30 `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($Body))
            $responseText = ""
            try {
                $responseText = [string]$resultResponse.Content
            } catch {
                $responseText = ""
            }
            if (-not $responseText) {
                return [pscustomobject]@{ ok = $true }
            }
            try {
                return $responseText | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-OwnerLogLine -Level "WARN" -Message ("result ack JSON parse failed for command {0}: {1}" -f $CommandId, $_.Exception.Message)
                return [pscustomobject]@{ ok = $true }
            }
        } catch {
            $attempt += 1
            $statusCode = Get-HttpStatusCode $_
            if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
                Write-Host "[AIMA] $(Get-LangText '设备凭据无效或已过期，正在退出。' 'Device token invalid or expired; exiting.')"
                Write-Host "[AIMA] $(Get-LangText '提交结果时凭据被拒绝，正在清理本地状态并停止。' 'Saved device credentials rejected while submitting command result; clearing local state and stopping.') (HTTP $statusCode)"
                Clear-DeviceState
                throw
            }
            if ($statusCode -ge 400 -and $statusCode -lt 500) {
                Write-Host "[AIMA] $(Get-LangText '命令结果被永久拒绝，不再重试相同 payload。' 'Command result rejected permanently; not retrying the same payload.') (HTTP $statusCode)"
                throw
            }
            $delay = [Math]::Min([Math]::Max($attempt * 5, 5), 60)
            Write-Host "[AIMA] $(Get-LangText '结果提交失败，将在' 'Result submit failed; retrying in') ${delay}s $(Get-LangText '后重试。' '.')"
            $remaining = $delay
            while ($remaining -gt 0) {
                Write-OwnerHeartbeat -Phase "result_retry_wait" -CommandId $CommandId
                $sleepChunk = [Math]::Min($remaining, 10)
                Start-Sleep -Seconds $sleepChunk
                $remaining -= $sleepChunk
            }
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

function Resolve-ActiveTaskIdForCommandExecution {
    if ($script:ActiveTaskId) {
        return [string]$script:ActiveTaskId
    }

    try {
        $activeResp = Get-ActiveTaskInfo
        if ($activeResp -and $activeResp.has_active_task -eq $true -and $activeResp.task_id) {
            return [string]$activeResp.task_id
        }
    } catch { }

    return "task-unknown"
}

function Invoke-DeviceCommand {
    param(
        [string]$CommandId,
        [string]$RawCommand,
        [string]$CommandEncoding = "",
        [int]$CommandTimeout = 300,
        [string]$CommandIntent = ""
    )

    $Command = $RawCommand
    if ($CommandEncoding -eq "base64") {
        try {
            $Command = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String($RawCommand))
        } catch {
            Write-Host "[AIMA] Base64 decode failed, using raw command"
        }
    }

    $startedAt = Get-Date
    if ($CommandIntent) {
        Show-AgentNotification -Phase "action" -Level "info" -Message $CommandIntent
    } else {
        $commandPreview = Get-CommandPreview -Command $Command
        Show-AgentNotification -Phase "action" -Level "warning" -Message (Get-LangText "未提供步骤说明，正在执行已授权命令：$commandPreview" "No step summary was provided; running authorized command: $commandPreview")
    }
    if ($CommandTimeout -gt 300) {
        Show-AgentNotification -Phase "waiting" -Level "info" -Message $script:UxRuntimeKeepOpen
    }
    if ($script:ShowRawCommands) {
        Write-Host "[AIMA] Executing: $Command"
    }
    $waitingSummary = if ($CommandIntent) { $CommandIntent } else { Get-CommandPreview -Command $Command }
    $stdoutText = ""
    $stderrText = ""
    $exitCode = 0
    $commandStatus = "failed"
    $startedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $completedAtUnix = 0
    $sandbox = $null
    $process = $null

    try {
        $sandbox = New-CommandExecutionSandbox `
            -TaskId (Resolve-ActiveTaskIdForCommandExecution) `
            -CommandId $CommandId `
            -CommandText $Command `
            -CommandIntent $CommandIntent
        Write-CommandExecutionJournal -Sandbox $sandbox -Status "prepared" -StartedAt $startedAtUnix

        $process = Start-Process -FilePath "cmd.exe" `
            -ArgumentList @("/d", "/c", "`"$($sandbox.RunnerPath)`"") `
            -PassThru `
            -WorkingDirectory $sandbox.WorkDir `
            -WindowStyle Hidden
        Write-CommandExecutionJournal -Sandbox $sandbox -Status "running" -ProcessId $process.Id -StartedAt $startedAtUnix

        $deadline = (Get-Date).AddSeconds($CommandTimeout)
        $nextProgressAt = (Get-Date).AddSeconds(5)
        $nextLocalWaitingNoticeAt = (Get-Date).AddSeconds(10)
        $nextHeartbeatAt = (Get-Date).AddSeconds(1)
        $remoteCancelRequested = $false
        Write-OwnerHeartbeat -Phase "command" -CommandId $CommandId

        while (-not $process.HasExited) {
            if ((Get-Date) -ge $nextHeartbeatAt) {
                Write-OwnerHeartbeat -Phase "command" -CommandId $CommandId
                $nextHeartbeatAt = (Get-Date).AddSeconds(1)
            }
            if (-not $script:RunAsOwner) {
                $hotkeyAction = Get-PendingHotkeyAction
                switch ($hotkeyAction) {
                    "cancel" {
                        $script:LocalCancelRequested = $true
                        Stop-ProcessTree -ProcessId $process.Id
                        $process.WaitForExit(5000) | Out-Null
                        $commandStatus = "cancelled"
                        $exitCode = 130
                        $stderrText = "Command cancelled locally"
                        [void](Cancel-ActiveTask)
                        return
                    }
                    "disconnect" {
                        Stop-ProcessTree -ProcessId $process.Id
                        $process.WaitForExit(5000) | Out-Null
                        $commandStatus = "cancelled"
                        $exitCode = 130
                        $stderrText = "Command interrupted because the device was disconnected"
                        Request-ExplicitDisconnect
                        return
                    }
                }
            }

            if ((Get-Date) -ge $deadline) {
                Stop-ProcessTree -ProcessId $process.Id
                $process.WaitForExit(5000) | Out-Null
                $exitCode = 124
                $commandStatus = "timed_out"
                $stderrText = "Command timed out after ${CommandTimeout}s"
                Write-Host "[AIMA] Command timed out after ${CommandTimeout}s"
                break
            }

            if ((Get-Date) -ge $nextProgressAt) {
                $elapsedSeconds = [int][Math]::Max(1, ((Get-Date) - $startedAt).TotalSeconds)
                $progressResponse = Submit-CommandProgress `
                    -CommandId $CommandId `
                    -StdoutText (Get-FileTailText -Path $sandbox.StdoutPath -MaxChars $script:CommandProgressTailMaxChars) `
                    -StderrText (Get-FileTailText -Path $sandbox.StderrPath -MaxChars $script:CommandProgressTailMaxChars) `
                    -Message ("Command still running ({0}s)" -f $elapsedSeconds)
                $nextProgressAt = (Get-Date).AddSeconds(5)
                if ((Get-Date) -ge $nextLocalWaitingNoticeAt) {
                    Show-AgentNotification `
                        -Phase "waiting" `
                        -Level "info" `
                        -Message (Get-LangText ("仍在执行：{0} ({1}s)。请保持窗口开启，不要中断。" -f $waitingSummary, $elapsedSeconds) ("Still working: {0} ({1}s). Keep this window open." -f $waitingSummary, $elapsedSeconds))
                    $nextLocalWaitingNoticeAt = (Get-Date).AddSeconds(15)
                }

                if (
                    $progressResponse -and (
                        $progressResponse.cancel_requested -eq $true -or
                        $progressResponse.command_status -eq "cancelled"
                    )
                ) {
                    Show-AgentNotification -Phase "waiting" -Level "warning" -Message $script:UxRuntimeRemoteCancel
                    Stop-ProcessTree -ProcessId $process.Id
                    $process.WaitForExit(5000) | Out-Null
                    $exitCode = 130
                    $commandStatus = "cancelled"
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

        $stdoutText = Get-FileTailText -Path $sandbox.StdoutPath -MaxChars $script:CommandResultTailMaxChars
        $capturedStderr = Get-FileTailText -Path $sandbox.StderrPath -MaxChars $script:CommandResultTailMaxChars
        if ($capturedStderr) {
            if ($stderrText) {
                $stderrText = $capturedStderr + "`n" + $stderrText
            } else {
                $stderrText = $capturedStderr
            }
        }
        if ($commandStatus -notin @("cancelled", "timed_out")) {
            $commandStatus = if ($exitCode -eq 0) { "completed" } else { "failed" }
        }
    } catch {
        $exitCode = 1
        $commandStatus = "failed"
        $stderrText = $_.Exception.Message
    } finally {
        $completedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($sandbox) {
            Write-CommandExecutionJournal `
                -Sandbox $sandbox `
                -Status $commandStatus `
                -ExitCode $exitCode `
                -ProcessId $(if ($process) { $process.Id } else { 0 }) `
                -StartedAt $startedAtUnix `
                -CompletedAt $completedAtUnix
        }
    }

    if ($script:LocalCancelRequested) {
        return
    }

    $elapsedSeconds = [int][Math]::Max(1, ((Get-Date) - $startedAt).TotalSeconds)
    if (-not $script:ShowRawCommands) {
        if ($exitCode -eq 0) {
            Write-Host ("  [Step] {0} ({1}s)" -f (Get-LangText '已完成' 'Completed'), $elapsedSeconds) -ForegroundColor Green
        } else {
            Write-Host ("  [Step] {0} (exit {1}, {2}s)" -f (Get-LangText '失败' 'Failed'), $exitCode, $elapsedSeconds) -ForegroundColor Red
        }
    }

    if ($stdoutText.Length -gt 524288) { $stdoutText = $stdoutText.Substring(0, 524288) }
    if ($stderrText.Length -gt 524288) { $stderrText = $stderrText.Substring(0, 524288) }

    $body = @{
        command_id = $CommandId
        exit_code  = $exitCode
        stdout     = $stdoutText
        stderr     = $stderrText
        result_id  = [System.Guid]::NewGuid().ToString()
    } | ConvertTo-Json -Compress

    return (Submit-CommandResult -Body $body -CommandId $CommandId)
}

function Copy-ToClipboard {
    param([string]$Text)

    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text
            return $true
        }
    } catch { }

    try {
        $Text | & clip.exe
        return $true
    } catch { }

    return $false
}

function Start-BindingFlow {
    $fingerprint = Get-Fingerprint
    $osProfile = Get-OSProfile

    Write-Host ""
    Write-Host "  $(Get-LangText '正在启动绑定流程...' 'Starting binding flow...')" -ForegroundColor DarkGray

    $body = @{
        fingerprint = $fingerprint
        os_profile = $osProfile
    } | ConvertTo-Json -Compress -Depth 5
    $headers = @{}
    if ($script:DeviceId -and $script:DeviceToken) {
        $body = @{
            device_id = $script:DeviceId
            fingerprint = $fingerprint
            os_profile = $osProfile
        } | ConvertTo-Json -Compress -Depth 5
        $headers["Authorization"] = "Bearer $($script:DeviceToken)"
    }

    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri "$BaseUrl/device-flows" `
            -Headers $headers `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
    } catch {
        $statusCode = Get-HttpStatusCode $_
        Write-Host "  $(Get-LangText '无法启动绑定流程' 'Failed to start binding flow.') (HTTP $statusCode)" -ForegroundColor Red
        return
    }

    if (-not $response.user_code -or -not $response.verification_uri) {
        Write-Host "  $(Get-LangText '服务器返回了无效的绑定信息' 'Server returned invalid binding info.')" -ForegroundColor Red
        return
    }

    $verificationUriWithCode = "$($response.verification_uri)?user_code=$([Uri]::EscapeDataString([string]$response.user_code))"

    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
    Write-Host "  $(Get-LangText '绑定设备到控制台' 'Link Device to Console')" -ForegroundColor White
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
    Write-Host "  1. $(Get-LangText '在浏览器中打开' 'Open in browser:')"
    Write-Host "     $verificationUriWithCode" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  2. $(Get-LangText '输入设备码' 'Enter device code:')"
    Write-Host "     $($response.user_code)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $(Get-LangText '浏览器会先检查控制台登录，再继续绑定。' 'The browser will verify Console login before continuing the binding flow.')" -ForegroundColor DarkGray
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta

    try {
        Start-Process $verificationUriWithCode | Out-Null
    } catch { }

    Write-Host "  $(Get-LangText '浏览器已打开。完成绑定后，终端会在下一次状态刷新时显示最新结果。' 'Browser opened. The terminal will show the latest binding state on the next refresh.')" -ForegroundColor DarkGray

    if ($script:DeviceId -and $script:DeviceToken) {
        Refresh-BindingState | Out-Null
    }
}

function Start-BrowserRecoveryFlow {
    param([Parameter(Mandatory=$true)][object]$Payload)

    $userCode = [string]$Payload.user_code
    $deviceCode = [string]$Payload.device_code
    $verificationUri = [string]$Payload.verification_uri
    $verificationUriWithCode = [string]$Payload.verification_uri_complete
    $interval = 2
    if ($Payload.interval) {
        try { $interval = [int]$Payload.interval } catch { $interval = 2 }
    }
    if (-not $verificationUriWithCode -and $verificationUri -and $userCode) {
        $verificationUriWithCode = "$verificationUri?user_code=$([Uri]::EscapeDataString($userCode))"
    }

    if (-not $userCode -or -not $deviceCode -or -not $verificationUri) {
        Write-Host "  $(Get-LangText '服务器返回了无效的恢复确认信息。' 'Server returned invalid recovery confirmation info.')" -ForegroundColor Red
        return $false
    }

    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
    Write-Host "  $(Get-LangText '在浏览器中确认恢复设备' 'Confirm Device Recovery in Browser')" -ForegroundColor White
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
    Write-Host "  1. $(Get-LangText '在浏览器中打开' 'Open in browser:')"
    Write-Host "     $verificationUriWithCode" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  2. $(Get-LangText '输入设备码' 'Enter device code:')"
    Write-Host "     $userCode" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $(Get-LangText '请使用原来的 device manager 账号确认恢复。确认后终端会自动继续。' 'Please sign in with the original device manager account to confirm recovery. The terminal will continue automatically after approval.')" -ForegroundColor DarkGray
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta

    try {
        Start-Process $verificationUriWithCode | Out-Null
    } catch { }

    Write-Host "  $(Get-LangText '浏览器已打开。正在等待恢复确认...' 'Browser opened. Waiting for recovery confirmation...')" -ForegroundColor DarkGray

    while ($true) {
        try {
            $poll = Invoke-RestMethod -Method Get `
                -Uri "$BaseUrl/device-flows/$deviceCode/poll" `
                -TimeoutSec 15
        } catch {
            Start-Sleep -Seconds $interval
            continue
        }

        $status = [string]$poll.status
        switch ($status) {
            "pending" {
                Start-Sleep -Seconds $interval
                continue
            }
            "bound" {
                if (-not $poll.device_id -or -not $poll.token -or -not $poll.recovery_code) {
                    Write-Host "  $(Get-LangText '恢复确认完成，但平台返回的凭据不完整。' 'Recovery confirmation succeeded, but the platform returned incomplete credentials.')" -ForegroundColor Red
                    return $false
                }
                $script:DeviceId = [string]$poll.device_id
                $script:DeviceToken = [string]$poll.token
                $script:RecoveryCode = [string]$poll.recovery_code
                Write-Host "  $(Get-LangText '浏览器已确认，设备恢复成功。' 'Browser confirmation complete. Device recovery succeeded.')" -ForegroundColor Green
                return $true
            }
            "expired" {
                Write-Host "  $(Get-LangText '恢复确认已过期，请重新运行 /go。' 'Recovery confirmation expired. Please rerun /go.')" -ForegroundColor Red
                return $false
            }
            "denied" {
                Write-Host "  $(Get-LangText '恢复确认被拒绝，请检查登录账号或重新发起恢复。' 'Recovery confirmation was denied. Check the signed-in account or restart recovery.')" -ForegroundColor Red
                return $false
            }
            default {
                Write-Host "  $(Get-LangText '恢复流程返回了未预期状态。' 'Recovery flow returned an unexpected status.')" -ForegroundColor Red
                return $false
            }
        }
    }
}

function Refresh-BindingState {
    if (-not $script:DeviceId -or -not $script:DeviceToken) {
        return $false
    }

    try {
        $sessionResp = Invoke-RestMethod -Method Get `
            -Uri "$BaseUrl/devices/$script:DeviceId/session" `
            -Headers (Get-Headers) `
            -TimeoutSec 10
        if ($null -ne $sessionResp.is_bound) {
            $script:IsBound = [bool]$sessionResp.is_bound
        } else {
            $script:IsBound = $false
        }
        return $true
    } catch {
        return $false
    }
}

function Refresh-AccountSnapshot {
    if (-not $script:DeviceId -or -not $script:DeviceToken) {
        return $false
    }

    try {
        $accountResp = Invoke-RestMethod -Method Get `
            -Uri "$BaseUrl/devices/$script:DeviceId/account" `
            -Headers (Get-Headers) `
            -TimeoutSec 10
        Sync-BudgetSnapshotFromBudgetObject -Budget $accountResp.budget
        if ($null -ne $accountResp.is_bound) {
            $script:IsBound = [bool]$accountResp.is_bound
        }
        if ($accountResp.referral_code) {
            $script:ReferralCode = [string]$accountResp.referral_code
        }
        return $true
    } catch {
        return $false
    }
}

function Show-AgentNotification {
    param(
        [string]$Phase = "progress",
        [string]$Level = "info",
        [string]$Message
    )

    if (-not $Message) { return }

    $prefix = "●"
    $color = "Gray"
    switch ($Phase) {
        "start"    { $prefix = "● [AIMA]"; $color = "Cyan" }
        "action"   { $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "➜ [操作]" } else { "➜ [Action]" }; $color = "Cyan" }
        "decision" { $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "● [决策]" } else { "● [Decision]" }; $color = "Yellow" }
        "waiting"  { $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "◌ [等待]" } else { "◌ [Waiting]" }; $color = "Cyan" }
        "blocked"  { $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "✖ [阻塞]" } else { "✖ [Blocked]" }; $color = "Red" }
        "result"   { $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "✔ [结果]" } else { "✔ [Result]" }; $color = "Green" }
    }
    switch ($Level) {
        "warning" {
            if ($Phase -ne "blocked") {
                $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "⚠ [警告]" } else { "⚠ [Warning]" }
            }
            $color = "Yellow"
        }
        "error"   {
            $prefix = if ($script:DisplayLanguage -eq "zh_cn") { "✖ [错误]" } else { "✖ [Error]" }
            $color = "Red"
        }
    }

    if ($script:RunAsOwner) {
        Write-SessionStatus -Phase $Phase -Level $Level -Message $Message
    }

    Write-Host ""
    Write-Host "  $prefix $Message" -ForegroundColor $color
}

function Show-ConnectionSecurityStatus {
    if ($BaseUrl -match '^https://') {
        Write-Host "       $(Get-LangText '链路已加密（HTTPS）' 'Connection: HTTPS encrypted')" -ForegroundColor DarkGray
        return
    }

    Write-Host "       $(Get-LangText '链路未加密，仅 HTTP 传输' 'Connection: HTTP only, not encrypted')" -ForegroundColor Yellow
}

function Respond-Interaction {
    param(
        [string]$InteractionId,
        [string]$Answer
    )

    $body = @{ answer = $Answer } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post `
            -Uri "$BaseUrl/devices/$script:DeviceId/interactions/$InteractionId/respond" `
            -Headers (Get-Headers) `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Handle-Interaction {
    param(
        [string]$InteractionId,
        [string]$Question,
        [string]$InteractionType = "info_request",
        [string]$InteractionLevel = "info",
        [string]$InteractionPhase = "progress",
        [string]$DisplayQuestion = ""
    )

    $renderedQuestion = Format-InteractionQuestion -Question $Question -DisplayQuestion $DisplayQuestion

    if ($InteractionType -eq "notification") {
        Show-AgentNotification -Phase $InteractionPhase -Level $InteractionLevel -Message $Question
        if (Respond-Interaction -InteractionId $InteractionId -Answer "displayed") {
            return 0
        }
        Write-Host "  $(Get-LangText '设备更新确认失败，稍后重试。' 'Failed to acknowledge device update; will retry.')"
        return 10
    }

    if ($script:RunAsOwner) {
        Write-PendingInteractionFile `
            -InteractionId $InteractionId `
            -Question $Question `
            -InteractionType $InteractionType `
            -InteractionLevel $InteractionLevel `
            -InteractionPhase $InteractionPhase `
            -DisplayQuestion $DisplayQuestion
        Write-SessionStatus -Phase $InteractionPhase -Level $InteractionLevel -Message $renderedQuestion

        $answerPayload = Get-JsonFileObject -Path $script:InteractionAnswerFile
        if ($answerPayload -and $answerPayload.interaction_id -eq $InteractionId -and $answerPayload.answer) {
            if (Respond-Interaction -InteractionId $InteractionId -Answer ([string]$answerPayload.answer)) {
                Clear-PendingInteractionFile
                Write-SessionStatus -Phase "result" -Level "info" -Message (Get-LangText '已发送你的回答。' 'Sent your answer.')
                return 0
            }
            Write-Host "  $(Get-LangText '回答发送失败，将重试。' 'Failed to send deferred answer; will retry.')"
            return 10
        }

        return 30
    }

    Write-Host ""
    Write-Host ">>> [$script:UxInteractionTitle]: $renderedQuestion"
    try {
        $answerPrompt = Read-ConsoleLine -Prompt $script:UxInteractionPrompt -AllowDisconnectHotkey $true
    } catch {
        Write-Host "  $(Get-LangText '当前终端不可交互，稍后会再次提问。' 'Non-interactive terminal; will retry this question later.')"
        return 30
    }
    if ($answerPrompt.action -eq "disconnect") {
        Request-ExplicitDisconnect
        return 30
    }
    $answer = [string]$answerPrompt.value
    $pasteContinuation = Read-ConsolePasteContinuation
    if ($pasteContinuation) {
        if ($answer) {
            $answer = "$answer`n$pasteContinuation"
        } else {
            $answer = $pasteContinuation
        }
    }
    if (-not $answer) {
        Write-Host "  $(Get-LangText '已跳过，稍后会再次提问。' 'Skipped; will wait a bit before asking again.')"
        return 20
    }

    if (Respond-Interaction -InteractionId $InteractionId -Answer $answer) {
        Write-Host "  $(Get-LangText '已发送。' 'Sent.')"
        return 0
    }
    Write-Host "  $(Get-LangText '回答发送失败，将重试。' 'Failed to send answer; will retry.')"
    return 10
}

function Show-TaskCompletionCard {
    param(
        [string]$TaskStatus,
        [object]$BudgetTasksRemaining = $null,
        [object]$BudgetTasksTotal = $null,
        [object]$BudgetUsdRemaining = $null,
        [object]$BudgetUsdTotal = $null,
        [string]$ReferralCode = "",
        [string]$ShareText = "",
        [string]$TaskMessage = "",
        [string]$BudgetWarning = "",
        [string]$BudgetBindingIncentive = ""
    )

    Refresh-WindowTitle

    if ($TaskStatus -eq "succeeded") {
        Write-Host ""
        Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "  ✓ $script:UxTaskCompletionSuccessTitle" -ForegroundColor Green
        if ($TaskMessage) {
            Write-Host "  $(Get-LangText '说明' 'Message'): $TaskMessage" -ForegroundColor DarkGray
        }
        if ($null -ne $BudgetTasksRemaining -or $null -ne $BudgetTasksTotal) {
            Write-Host "  $(Get-LangText '任务额度' 'Task budget'): $(Format-TaskBudgetRemainingLine -Remaining $BudgetTasksRemaining -Total $BudgetTasksTotal)" -ForegroundColor DarkGray
        }
        if ($null -ne $BudgetUsdRemaining -or $null -ne $BudgetUsdTotal) {
            Write-Host "  $(Get-LangText '金额额度' 'Amount budget'): $(Format-AmountBudgetRemainingLine -Remaining $BudgetUsdRemaining -Total $BudgetUsdTotal)" -ForegroundColor DarkGray
        }

        if ($BudgetWarning) {
            Write-Host ""
            Write-Host "  ⚠ $BudgetWarning" -ForegroundColor Yellow
            if ($BudgetBindingIncentive) {
                Write-Host "  💡 $BudgetBindingIncentive" -ForegroundColor Yellow
            }
        }

        if ($ReferralCode) {
            Write-Host ""
            Write-Host "  $script:UxTaskCompletionShareHeading" -ForegroundColor Yellow
            Write-Host "  $(Get-LangText '每邀请一位好友，双方各得 $10 + 5 次任务额度' 'Invite a friend and both of you get $10 + 5 task credits.')"
            Write-Host "  $(Get-LangText '推荐码' 'Referral code'): $ReferralCode" -ForegroundColor Yellow
            Write-Host "  $script:UxTaskCompletionSharePrompt" -ForegroundColor DarkGray
        }

        if (-not $script:IsBound) {
            Write-Host ""
            Write-Host "  $(Get-LangText '想在控制台里管理这台设备？' 'Manage this device in Console?')" -ForegroundColor Magenta
            Write-Host "  $(Get-LangText '绑定到 Console workspace，开启审批、历史和预算。' 'Bind this device to Console to unlock approvals, history, and budget control.')"
            Write-Host "  $script:UxTaskCompletionBindPrompt" -ForegroundColor White -BackgroundColor DarkMagenta
        }
        Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "  ❌ $script:UxTaskCompletionFailureTitle" -ForegroundColor Red
        if ($TaskMessage) {
            Write-Host "  $(Get-LangText '原因' 'Reason'): $TaskMessage" -ForegroundColor Yellow
        }
        if ($null -ne $BudgetTasksRemaining -or $null -ne $BudgetTasksTotal) {
            Write-Host "  $(Get-LangText '任务额度' 'Task budget'): $(Format-TaskBudgetRemainingLine -Remaining $BudgetTasksRemaining -Total $BudgetTasksTotal)" -ForegroundColor DarkGray
        }
        if ($null -ne $BudgetUsdRemaining -or $null -ne $BudgetUsdTotal) {
            Write-Host "  $(Get-LangText '金额额度' 'Amount budget'): $(Format-AmountBudgetRemainingLine -Remaining $BudgetUsdRemaining -Total $BudgetUsdTotal)" -ForegroundColor DarkGray
        }
    }

    if (($ReferralCode -or -not $script:IsBound) -and -not [System.Console]::IsInputRedirected) {
        Write-Host ""
        try {
            $promptParts = @()
            if ($ReferralCode) {
                $promptParts += "[c] " + (Get-LangText '复制分享文案' 'Copy share text')
            }
            if (-not $script:IsBound) {
                $promptParts += "[Ctrl+B] " + (Get-LangText '绑定到控制台' 'Bind to console')
            }
            $promptParts += "[Enter] " + (Get-LangText '继续' 'Continue')
            $choice = Read-ConsoleLine -Prompt ("  " + ($promptParts -join "  ") + " ") -AllowBindHotkey $true
        } catch {
            $choice = ""
        }

        if ($choice.action -eq "bind") {
            Start-BindingFlow
        } elseif ($choice.value -match '^[cC]$') {
            if ($ShareText -and (Copy-ToClipboard -Text $ShareText)) {
                Write-Host "  $script:UxTaskCompletionCopiedNotice" -ForegroundColor Green
            } elseif ($ShareText) {
                Write-Host "  $(Get-LangText '请手动复制以下文案：' 'Copy this text manually:')"
                Write-Host "  $ShareText"
            }
        }
    }
}

# ── Self-register ────────────────────────────────────────────────

function Register-DeviceSelfService {
    Write-Host ""
    Write-Host "  ● [2/4] $(Get-LangText '正在注册设备...' 'Registering device...')" -ForegroundColor Cyan

    if (Load-RecoveryCodeFromSavedState) {
        Write-Host "  $(Get-LangText '已从本机其他 AIMA saved state 找回恢复码，将继续尝试恢复设备。' 'Recovered a saved recovery code from another local AIMA state file and will continue device recovery.')" -ForegroundColor Yellow
    }

    $response = $null
    while ($true) {
        $osProfile = Get-OSProfile
        $body = @{
            fingerprint = (Get-Fingerprint)
            os_profile  = $osProfile
        }
        if ($script:InviteCode) {
            $body["invite_code"] = $script:InviteCode
        }
        if ($WorkerEnrollmentCode) {
            $body["worker_enrollment_code"] = $WorkerEnrollmentCode
        }
        if ($ReferralCode) {
            $body["referral_code"] = $ReferralCode
        }
        if ($UtmSource) {
            $body["utm_source"] = $UtmSource
        }
        if ($UtmMedium) {
            $body["utm_medium"] = $UtmMedium
        }
        if ($UtmCampaign) {
            $body["utm_campaign"] = $UtmCampaign
        }
        if ($osProfile.hardware_id) {
            $body["hardware_id"] = $osProfile.hardware_id
        }
        if ($script:RecoveryCode) {
            $body["recovery_code"] = $script:RecoveryCode
        }
        $jsonBody = $body | ConvertTo-Json -Compress -Depth 3
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

        $needsFreshInviteCode = $false
        $maxAttempts = 5
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $response = Invoke-RestMethod -Method Post `
                    -Uri "$BaseUrl/devices/self-register" `
                    -ContentType "application/json; charset=utf-8" `
                    -Body $bodyBytes
                break
            } catch {
                $sc = Get-HttpStatusCode $_
                $detail = Get-ErrorDetail $_
                $payload = Get-ErrorPayload $_
                $reauthMethod = if ($payload) { [string]$payload.reauth_method } else { "" }
                $recoveryCodeStatus = if ($payload) { [string]$payload.recovery_code_status } else { "" }
                $errorCode = if ($payload) { [string]$payload.error_code } else { "" }
                # Structured invite error_code — clear stale invite and re-prompt
                if ($errorCode -in @('invite_quota_exhausted', 'invite_expired', 'invite_disabled')) {
                    $script:InviteCode = $null
                    Prompt-InviteCode -Reason "$(Get-LangText '当前邀请码不可用' 'Current invite code is unavailable'): $detail"
                    $needsFreshInviteCode = $true
                    break
                }
                if ($errorCode -eq 'invite_invalid') {
                    $script:InviteCode = $null
                    Prompt-InviteCode -Reason "$(Get-LangText '邀请码无效' 'Invalid invite code')"
                    $needsFreshInviteCode = $true
                    break
                }
                if ($errorCode -in @('invite_required', 'referral_error')) {
                    Prompt-InviteCode -Reason "$script:UxInviteRequired`n  $detail"
                    $needsFreshInviteCode = $true
                    break
                }
                # Legacy fallback: grep detail string for older servers without error_code
                if ($detail -and $detail -match '(?i)(referral|invite_code|invite code.*(exhaust|expired|disabled))') {
                    $script:InviteCode = $null
                    Prompt-InviteCode -Reason "$script:UxReferralNeedsCode`n  $detail"
                    $needsFreshInviteCode = $true
                    break
                }
                if ($sc -eq 409 -and $payload -and $reauthMethod -eq "browser_confirmation") {
                    if (Start-BrowserRecoveryFlow -Payload $payload) {
                        return
                    }
                    throw
                }
                if ($reauthMethod -eq "recovery_code") {
                    $promptReason = if ($recoveryCodeStatus -eq "missing" -and -not $script:RecoveryCode) {
                        $script:UxRecoveryMissingLocalState
                    } elseif ($detail) {
                        $detail
                    } else {
                        $script:UxRecoveryMissingLocalState
                    }
                    Prompt-RecoveryCode -Reason $promptReason
                    $needsFreshInviteCode = $true
                    break
                }
                if ($sc -eq 409) {
                    throw
                }
                if ($detail -and $detail -match '(?i)recovery_code') {
                    $promptReason = if (-not $script:RecoveryCode) {
                        $script:UxRecoveryMissingLocalState
                    } elseif ($detail) {
                        $detail
                    } else {
                        $script:UxRecoveryMissingLocalState
                    }
                    Prompt-RecoveryCode -Reason $promptReason
                    $needsFreshInviteCode = $true
                    break
                }
                if ($sc -and $sc -lt 500) { throw }  # other 4xx: don't retry
                if ($attempt -lt $maxAttempts) {
                    $delay = [Math]::Min($attempt * 3, 15)
                    Write-Host "  ◌ [AIMA] $(Get-LangText ('注册失败，{0}s 后重试（第 {1} 次）。' -f $delay, $attempt) ('Registration failed; retrying in {0}s (attempt {1}).' -f $delay, $attempt))" -ForegroundColor Yellow
                    Start-Sleep -Seconds $delay
                } else {
                    throw
                }
            }
        }

        if ($response) { break }
        if ($needsFreshInviteCode) { continue }
        throw (Get-LangText '注册失败。' 'Registration failed.')
    }

    if ($response.device_id -and $response.token -and $response.recovery_code) {
        $script:DeviceId = $response.device_id
        $script:DeviceToken = $response.token
        $script:RecoveryCode = $response.recovery_code
        Sync-BudgetSnapshotFromBudgetObject -Budget $response.budget
        if ($response.referral_code) {
            $script:ReferralCode = [string]$response.referral_code
        }

        return
    }
}

# ── Feedback ─────────────────────────────────────────────────────

function Submit-FeedbackQuick {
    param(
        [string]$FeedbackType,
        [string]$TaskId = $script:ActiveTaskId
    )
    Write-Host "  $script:UxFeedbackDescribePrompt"
    try {
        $desc = Read-Host "  > "
    } catch {
        $desc = ""
    }

    $osProfile = Get-OSProfile
    $body = @{
        type = $FeedbackType
        environment = $osProfile
        context = @{
            session_uptime_seconds = [int]((Get-Date) - $script:SessionStart).TotalSeconds
            script_version = "go.ps1/1.0"
        }
    }
    if ($TaskId) { $body.context["task_id"] = $TaskId }
    if ($desc) { $body["description"] = $desc }

    $jsonBody = $body | ConvertTo-Json -Compress -Depth 3
    try {
        $resp = Invoke-DeviceApi -Method Post `
            -Uri "$BaseUrl/devices/$script:DeviceId/feedback" `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody))
        if ($resp.feedback_id) {
            Write-Host "  $(Get-LangText '已提交' 'Submitted'): $($resp.feedback_id)" -ForegroundColor Green
        }
    } catch {
        Write-Host "  $(Get-LangText '提交失败' 'Submission failed'): $_" -ForegroundColor Red
    }
}

function Submit-Feedback {
    param([string]$TaskId = $script:ActiveTaskId)
    Write-Host ""
    Write-Host "  $script:UxFeedbackTitle"
    Write-Host "  [b] $script:UxFeedbackBugOption"
    Write-Host "  [s] $script:UxFeedbackSuggestionOption"
    Write-Host "  [Enter] $script:UxFeedbackGoBackOption"
    try {
        $choice = Read-Host "  > "
    } catch {
        return
    }
    switch -Regex ($choice) {
        '^[bB]$' { Submit-FeedbackQuick -FeedbackType "bug_report" -TaskId $TaskId }
        '^[sS]$' { Submit-FeedbackQuick -FeedbackType "suggestion" -TaskId $TaskId }
    }
}

function Prompt-PostTaskFeedback {
    param([string]$TaskId = "")
    if ([System.Console]::IsInputRedirected) { return }
    Write-Host ""
    Write-Host "  $script:UxPostTaskFeedbackPrompt" -ForegroundColor DarkGray
    try {
        $choice = Read-Host "  > "
    } catch {
        return
    }
    switch -Regex ($choice) {
        '^[fF]$' { Submit-FeedbackQuick -FeedbackType "bug_report" -TaskId $TaskId }
        '^[sS]$' { Submit-FeedbackQuick -FeedbackType "suggestion" -TaskId $TaskId }
    }
}

function Show-ActiveTaskResumeStatus {
    param([object]$ActiveTask)

    if (-not $ActiveTask -or -not $ActiveTask.task_id) {
        return
    }

    Write-Host "  $(Get-LangText '继续任务' 'Resuming task'): $($ActiveTask.task_id)"
    if ($ActiveTask.target) {
        Write-Host "    $($ActiveTask.target)"
    }
    if ([string]$ActiveTask.status -eq "paused_device_offline") {
        Write-Host "  $(Get-LangText '平台之前因设备疑似离线暂停了此任务，正在重新附着。' 'Platform had paused this task because the device looked offline. Re-attaching now...')" -ForegroundColor Yellow
    }
    Write-Host "  $script:UxTaskMenuResumeHotkeyHint"
}

function Prompt-AttachedActiveTaskAction {
    param([object]$ActiveTask)

    if (-not $ActiveTask -or -not $ActiveTask.task_id) {
        return "resume"
    }

    Write-Host ""
    Write-Host "  $script:UxActiveTaskTitle" -ForegroundColor Yellow
    Write-Host "    $script:UxActiveTaskTaskIdLabel: $($ActiveTask.task_id)"
    if ($ActiveTask.status) {
        Write-Host "    $script:UxActiveTaskStatusLabel: $($ActiveTask.status)" -ForegroundColor DarkGray
    }
    if ($ActiveTask.target) {
        Write-Host "    $script:UxActiveTaskTargetLabel: $($ActiveTask.target)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "    1  $script:UxActiveTaskResumeLabel"
    Write-Host "    2  $script:UxActiveTaskCancelLabel"
    Write-Host "    D  $script:UxActiveTaskDisconnectLabel"

    if ([System.Console]::IsInputRedirected) {
        Write-Host "  $script:UxActiveTaskNonInteractiveNotice" -ForegroundColor Yellow
        return "resume"
    }

    while ($true) {
        $choice = Read-ConsoleLine -Prompt "  > " -AllowDisconnectHotkey $true
        switch ($choice.action) {
            "disconnect" {
                Request-ExplicitDisconnect
                return "disconnect"
            }
            "exit_ui" {
                $script:UiExitRequested = $true
                return "exit_ui"
            }
            "submit" {
                switch -Regex ($choice.value.Trim()) {
                    '^[1rR]$' { return "resume" }
                    '^[2cC]$' { return "cancel" }
                    '^[dD]$' {
                        Request-ExplicitDisconnect
                        return "disconnect"
                    }
                    '^(?i:exit|quit)$' { return "exit_ui" }
                    default {
                        Write-Host "  $script:UxActiveTaskInvalidNotice" -ForegroundColor Yellow
                    }
                }
            }
            default {
                Write-Host "  $script:UxActiveTaskInputUnavailableNotice" -ForegroundColor Yellow
                return "resume"
            }
        }
    }
}

# ── Task menu ────────────────────────────────────────────────────

function Show-TaskMenu {
    # Check for existing active task
    $activeResp = Get-ActiveTaskInfo
    if ($activeResp -and $activeResp.has_active_task -eq $true) {
        $script:ActiveTaskId = [string]$activeResp.task_id
        $script:ActiveTaskLookupMisses = 0
        $action = Prompt-AttachedActiveTaskAction -ActiveTask $activeResp
        switch ($action) {
            "resume" {
                $script:ConfirmedActiveTaskId = $script:ActiveTaskId
                Show-ActiveTaskResumeStatus -ActiveTask $activeResp
                return
            }
            "cancel" {
                [void](Cancel-ActiveTask)
                return
            }
            default {
                return
            }
        }
    }
    $script:ActiveTaskId = $null
    $script:ConfirmedActiveTaskId = $null
    $script:LastVisibleActiveTaskId = $null
    $script:ActiveTaskLookupMisses = 0

    while ($true) {
        # Show menu
        Refresh-WindowTitle
        $submitHint = $script:UxTaskMenuSubmitHint
        if (-not $script:IsBound) {
            $submitHint = "$submitHint   $($script:BindConsoleHotkeyLabel)  $(Get-LangText '绑定控制台' 'Bind console')"
        }
        Write-Host ""
        Write-Host "  $script:UxTaskMenuReadyTitle"
        if ($script:UxTaskMenuSubtitle) {
            Write-Host "    $script:UxTaskMenuSubtitle" -ForegroundColor DarkGray
        }
        Write-Host ""
        if ($script:UxTaskMenuFreeformHint) {
            Write-Host "    $script:UxTaskMenuFreeformHint" -ForegroundColor DarkGray
        }
        foreach ($example in @($script:UxTaskMenuExample1, $script:UxTaskMenuExample2, $script:UxTaskMenuExample3)) {
            if ($example) {
                Write-Host "    - $example" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
        Write-Host "    $submitHint" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  $script:UxTaskMenuPrompt" -ForegroundColor Cyan

        if ([System.Console]::IsInputRedirected) { return }

        $menuInput = Read-ConsoleLine -Prompt "  > " -PromptColor "Cyan" -AllowDisconnectHotkey $true -AllowBindHotkey $true
        switch ($menuInput.action) {
            "exit_ui" {
                $script:UiExitRequested = $true
                return
            }
            "bind" {
                Start-BindingFlow
                continue
            }
            "disconnect" {
                Request-ExplicitDisconnect
                return
            }
            "cancel" {
                [void](Cancel-ActiveTask)
                if ($script:LocalCancelRequested) {
                    $script:LocalCancelRequested = $false
                }
                continue
            }
            "unavailable" {
                return
            }
        }
        $userRequest = [string]$menuInput.value
        $taskDescription = $null
        $taskMode = $null
        $taskUserRequest = $null
        $taskTypeHint = $null
        $softwareHint = $null
        $problemHint = $null
        $targetHint = $null
        $errorMessageHint = $null

        switch ($userRequest) {
            "0" {
                Submit-Feedback
                continue
            }
            "1" {
                $userRequest = Build-GuidedTaskRequest -FlowKey "install_software"
                if ($userRequest) {
                    $taskMode = "install_software"
                    $taskTypeHint = "software_install"
                    if ($script:GuidedTaskPrimaryAnswer) {
                        $taskUserRequest = [string]$script:GuidedTaskPrimaryAnswer
                    } else {
                        $taskUserRequest = [string]$userRequest
                    }
                    $softwareHint = Get-SoftwareHintFromText -Text $taskUserRequest
                    $targetHint = $softwareHint
                    $taskDescription = $script:UxTaskMenuAction1
                    if ($taskUserRequest -and $taskUserRequest -ne $taskDescription) {
                        $taskDescription = "$($script:UxTaskMenuAction1): $taskUserRequest"
                    }
                }
            }
            "2" {
                $userRequest = Build-GuidedTaskRequest -FlowKey "repair_software"
                if ($userRequest) {
                    $taskMode = "repair_software"
                    $taskTypeHint = "software_repair"
                    if ($script:GuidedTaskPrimaryAnswer) {
                        $taskUserRequest = [string]$script:GuidedTaskPrimaryAnswer
                    } else {
                        $taskUserRequest = [string]$userRequest
                    }
                    $softwareHint = Get-SoftwareHintFromText -Text $taskUserRequest
                    $targetHint = $softwareHint
                    $problemHint = $taskUserRequest
                    $errorMessageHint = $taskUserRequest
                    $taskDescription = $script:UxTaskMenuAction2
                    if ($taskUserRequest -and $taskUserRequest -ne $taskDescription) {
                        $taskDescription = "$($script:UxTaskMenuAction2): $taskUserRequest"
                    }
                }
            }
            "" { continue }
            default {
                if ($userRequest -match '^\d+$') {
                    Write-Host "  $(Get-UxTextLang -Path 'blocks.task_menu.context.invalid_selection_notice' -Fallback '请直接输入你的需求，按 0 可反馈问题，或使用 Ctrl+B / Ctrl+D。')" -ForegroundColor Yellow
                    continue
                }
                $taskMode = "freeform"
                $taskUserRequest = $userRequest
                $taskDescription = $userRequest
                $taskTypeHint = Get-TaskTypeHintFromText -Text $taskUserRequest
                $softwareHint = Get-SoftwareHintFromText -Text $taskUserRequest
                $targetHint = $softwareHint
                if ($taskTypeHint -eq "software_repair") {
                    $problemHint = $taskUserRequest
                    $errorMessageHint = $taskUserRequest
                }
            }
        }

        if ($userRequest -eq "__disconnect__" -or $userRequest -eq "__exit_ui__") {
            return
        }
        if (-not $taskDescription) {
            continue
        }

        if ($taskDescription) {
            Clear-TaskRuntimeState
            Reset-AttachRuntimeCache
            Write-Host "  $(Get-LangText '正在提交任务...' 'Submitting task...')"
            $body = New-TaskRequestBody `
                -Description $taskDescription `
                -Mode $taskMode `
                -UserRequest $taskUserRequest `
                -Renderer "go_powershell" `
                -TaskTypeHint $taskTypeHint `
                -SoftwareHint $softwareHint `
                -ProblemHint $problemHint `
                -TargetHint $targetHint `
                -ErrorMessageHint $errorMessageHint
            try {
                $taskResp = Invoke-DeviceApi -Method Post `
                    -Uri "$BaseUrl/devices/$script:DeviceId/tasks" `
                    -ContentType "application/json; charset=utf-8" `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
                if ($taskResp.task_id) {
                    $script:ActiveTaskId = $taskResp.task_id
                    $script:ConfirmedActiveTaskId = $script:ActiveTaskId
                    $script:LastVisibleActiveTaskId = $null
                    $script:ActiveTaskLookupMisses = 0
                    Write-Host "  $(Get-LangText '任务已创建' 'Task created'): $($taskResp.task_id)"
                }
            } catch {
                if (-not (Adopt-ActiveTaskAfterSubmitFailure -SubmittedDescription $taskDescription)) {
                    $statusCode = Get-HttpStatusCode $_
                    $detail = Get-ErrorDetail $_
                    if (-not $detail) {
                        $detail = $_.Exception.Message
                    }
                    if ($statusCode -eq 402 -or (($detail -as [string]) -match '(?i)device budget exhausted')) {
                        Write-Host "  $(Get-LangText '当前设备额度已用完，请在控制台补充额度，或换一台仍有额度的设备后重试。' 'This device has no remaining task budget. Add budget in the console or use a device with remaining budget, then retry.')"
                    } else {
                        Write-Host "  $(Get-LangText '创建任务失败' 'Task creation failed'): $detail"
                    }
                }
            }
        }
        return
    }
}

function Attach-ShowStatusIfChanged {
    param([string]$CurrentActiveTaskId = $null)

    $statusPayload = Get-JsonFileObject -Path $script:SessionStatusFile
    if (-not $statusPayload -or -not $statusPayload.message) {
        return $false
    }
    if (
        $statusPayload.active_task_id -and (
            (-not $CurrentActiveTaskId) -or
            ([string]$statusPayload.active_task_id -ne [string]$CurrentActiveTaskId)
        )
    ) {
        return $false
    }

    $statusKey = "{0}|{1}|{2}|{3}" -f `
        ([string]$statusPayload.phase), `
        ([string]$statusPayload.level), `
        ([string]$statusPayload.message), `
        ([string]$statusPayload.active_task_id)
    if ($statusKey -eq $script:AttachLastStatusKey) {
        return $false
    }

    $script:AttachLastStatusKey = $statusKey
    Show-AgentNotification `
        -Phase ([string]$statusPayload.phase) `
        -Level ([string]$statusPayload.level) `
        -Message ([string]$statusPayload.message)
    return $true
}

function Attach-HandlePendingInteraction {
    param([string]$CurrentActiveTaskId = $null)

    $payload = Get-JsonFileObject -Path $script:PendingInteractionFile
    if (-not $payload -or -not $payload.interaction_id) {
        return $false
    }
    if (
        $payload.active_task_id -and (
            (-not $CurrentActiveTaskId) -or
            ([string]$payload.active_task_id -ne [string]$CurrentActiveTaskId)
        )
    ) {
        Clear-PendingInteractionFile
        return $false
    }
    $interactionId = [string]$payload.interaction_id
    if ($script:AttachLastInteractionId -eq $interactionId) {
        return $false
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (
        $script:AttachDeferredInteractionId -eq $interactionId -and
        [int64]$script:AttachInteractionRetryAfter -gt $now
    ) {
        return $false
    }

    $displayQuestion = if ($payload.display_question) { [string]$payload.display_question } else { "" }
    $renderedQuestion = Format-InteractionQuestion -Question ([string]$payload.question) -DisplayQuestion $displayQuestion

    Write-Host ""
    Write-Host ">>> [$script:UxInteractionTitle]: $renderedQuestion"
    $answerPrompt = Read-ConsoleLine -Prompt $script:UxInteractionPrompt -AllowDisconnectHotkey $true
    if ($answerPrompt.action -eq "exit_ui") {
        $script:UiExitRequested = $true
        return $true
    }
    if ($answerPrompt.action -eq "disconnect") {
        Request-ExplicitDisconnect
        return $true
    }

    $answer = [string]$answerPrompt.value
    $pasteContinuation = Read-ConsolePasteContinuation
    if ($pasteContinuation) {
        if ($answer) {
            $answer = "$answer`n$pasteContinuation"
        } else {
            $answer = $pasteContinuation
        }
    }
    if (-not $answer) {
        $script:AttachDeferredInteractionId = $interactionId
        $script:AttachInteractionRetryAfter = $now + 30
        Write-Host "  $(Get-LangText '已跳过，稍后会再次提问。' 'Skipped; will wait a bit before asking again.')"
        return $true
    }

    $script:AttachLastInteractionId = $interactionId
    $script:AttachDeferredInteractionId = $null
    $script:AttachInteractionRetryAfter = [int64]0
    Write-InteractionAnswerFile -InteractionId $interactionId -Answer $answer
    Write-Host "  $script:UxInteractionQueuedNotice" -ForegroundColor Green
    return $true
}

function Attach-HandleTaskCompletion {
    $payload = Get-JsonFileObject -Path $script:TaskCompletionFile
    if (-not $payload -or -not $payload.task_id) {
        return $false
    }
    $taskId = [string]$payload.task_id
    $taskStatus = [string]$payload.task_status
    if (
        $script:LastLocallyCancelledTaskId -and
        $taskId -eq $script:LastLocallyCancelledTaskId -and
        $taskStatus -ne "succeeded"
    ) {
        $script:LastLocallyCancelledTaskId = $null
        Clear-TaskRuntimeState
        return $true
    }
    if ($script:AttachLastCompletionId -eq $taskId) {
        return $false
    }

    $script:AttachLastCompletionId = $taskId
    Show-TaskCompletionCard `
        -TaskStatus $taskStatus `
        -BudgetTasksRemaining $payload.budget_tasks_remaining `
        -BudgetTasksTotal $payload.budget_tasks_total `
        -BudgetUsdRemaining $payload.budget_usd_remaining `
        -BudgetUsdTotal $payload.budget_usd_total `
        -ReferralCode ([string]$payload.referral_code) `
        -ShareText ([string]$payload.share_text) `
        -TaskMessage ([string]$payload.task_message) `
        -BudgetWarning ([string]$payload.budget_warning) `
        -BudgetBindingIncentive ([string]$payload.budget_binding_incentive)
    Prompt-PostTaskFeedback -TaskId $taskId
    Clear-TaskRuntimeState
    return $true
}

function Show-AttachedUiLoop {
    Show-AttachedBanner

    while ($true) {
        $ownerHealthDetail = Get-OwnerHealthDetail
        if ($ownerHealthDetail) {
            Write-Host "  $(Get-LangText '后台会话看起来已经失活，正在重启本地 owner。' 'Background session looks unhealthy; restarting local owner.')" -ForegroundColor Yellow
            Write-OwnerLogLine -Level "WARN" -Message "launcher detected unhealthy owner while attached: $ownerHealthDetail"
            if (-not (Start-OwnerProcess)) {
                Write-OwnerLogLine -Level "ERROR" -Message "launcher failed to restart owner while attached: $ownerHealthDetail"
                Write-Host "  $(Get-LangText '无法重启后台会话，请检查本地日志后重新运行 /go。' 'Failed to restart the background session. Please run /go again after checking the local logs.')" -ForegroundColor Red
                $script:AttachModeFailed = $true
                $script:UiExitRequested = $true
                return
            }
            Write-OwnerLogLine -Level "INFO" -Message "launcher restarted background owner while attached: $ownerHealthDetail"
            $script:AttachLastStatusKey = $null
            $script:AttachLastInteractionId = $null
            $script:AttachDeferredInteractionId = $null
            $script:AttachInteractionRetryAfter = [int64]0
            $script:AttachLastCompletionId = $null
            $script:ActiveTaskId = $null
            $script:ConfirmedActiveTaskId = $null
            $script:LastVisibleActiveTaskId = $null
            $script:ActiveTaskLookupMisses = 0
            Start-Sleep -Seconds 1
            continue
        }
        $hotkeyAction = Get-PendingHotkeyAction
        switch ($hotkeyAction) {
            "bind" {
                Start-BindingFlow
            }
            "cancel" {
                [void](Cancel-ActiveTask)
            }
            "disconnect" {
                Request-ExplicitDisconnect
                return
            }
        }

        if ($script:LocalCancelRequested) {
            $script:LocalCancelRequested = $false
        }

        $activeResp = Get-ActiveTaskInfo
        $currentAttachTaskId = $null
        if ($activeResp -and $activeResp.has_active_task -eq $true -and $activeResp.task_id) {
            $currentAttachTaskId = [string]$activeResp.task_id
        } else {
            $currentAttachTaskId = Get-OwnerActiveTaskId
        }

        if ($currentAttachTaskId) {
            $script:ActiveTaskId = [string]$currentAttachTaskId
            $script:ActiveTaskLookupMisses = 0
            [void](Attach-HandlePendingInteraction -CurrentActiveTaskId $currentAttachTaskId)
            [void](Attach-ShowStatusIfChanged -CurrentActiveTaskId $currentAttachTaskId)
            if ($script:UiExitRequested) {
                return
            }
        } else {
            [void](Attach-HandleTaskCompletion)
            if ($script:UiExitRequested) {
                return
            }
        }

        if ($activeResp -and $activeResp.has_active_task -eq $true -and $activeResp.task_id) {
            $script:ActiveTaskId = [string]$activeResp.task_id
            $script:ActiveTaskLookupMisses = 0
            if ($script:ConfirmedActiveTaskId -ne $script:ActiveTaskId) {
                $resumeAction = Prompt-AttachedActiveTaskAction -ActiveTask $activeResp
                switch ($resumeAction) {
                    "resume" {
                        $script:ConfirmedActiveTaskId = $script:ActiveTaskId
                        Show-ActiveTaskResumeStatus -ActiveTask $activeResp
                    }
                    "cancel" {
                        [void](Cancel-ActiveTask)
                        Start-Sleep -Seconds 1
                        continue
                    }
                    "disconnect" {
                        return
                    }
                    "exit_ui" {
                        return
                    }
                    default {
                        $script:ConfirmedActiveTaskId = $script:ActiveTaskId
                    }
                }
            }
            if ($script:LastVisibleActiveTaskId -ne $script:ActiveTaskId) {
                Write-Host "  $(Get-LangText '已连接任务' 'Attached task'): $script:ActiveTaskId" -ForegroundColor Green
                if ($activeResp.target) {
                    Write-Host "    $($activeResp.target)" -ForegroundColor DarkGray
                }
                $script:LastVisibleActiveTaskId = $script:ActiveTaskId
            }
            Start-Sleep -Seconds 1
            continue
        }

        if ($currentAttachTaskId) {
            Start-Sleep -Seconds 1
            continue
        }

        if ($script:ActiveTaskId -and $script:ActiveTaskLookupMisses -lt $script:ActiveTaskLookupGraceMisses) {
            $script:ActiveTaskLookupMisses += 1
            Start-Sleep -Seconds 1
            continue
        }

        $script:LastVisibleActiveTaskId = $null
        $script:ConfirmedActiveTaskId = $null
        $script:ActiveTaskId = $null
        $script:ActiveTaskLookupMisses = 0
        Clear-TaskRuntimeState
        Reset-AttachRuntimeCache
        Show-TaskMenu
        if ($script:ExplicitDisconnectRequested -or $script:UiExitRequested) {
            return
        }
        Start-Sleep -Seconds 1
    }
}

# ── Main ─────────────────────────────────────────────────────────

if ($script:RunAsOwner) {
    Ensure-RuntimeDirectory
    if (Load-DeviceState) {
        if ($script:DisplayLanguage) {
            Reload-UxStrings
        }
    }
    Clear-RuntimeOwnerBootstrapFiles
    [System.Diagnostics.Process]::GetCurrentProcess().Id | Set-Content -LiteralPath $script:OwnerPidFile -Encoding ascii
    Protect-StateFilePermissions -Path $script:OwnerPidFile
    Write-SessionStatus -Phase "start" -Level "info" -Message $script:UxBackgroundSessionBooting
    Write-OwnerHeartbeat -Phase "booting"
}

try {
    Initialize-ConsoleEncoding

    # Step 1: Detect system
    Write-Host ""
    Write-Host "  1/4  $(Get-LangText '检测系统环境...' 'Detecting system environment...')" -ForegroundColor Cyan
    $osVersion = Get-OSVersion
    $arch = Get-Architecture
    Write-Host "       $osVersion ($arch) - $env:COMPUTERNAME" -ForegroundColor DarkGray
    $pkgMgrs = Get-PackageManagers
    if ($pkgMgrs.Count -gt 0) { Write-Host "       Package managers: $($pkgMgrs -join ', ')" -ForegroundColor DarkGray }

    # Step 2: Register or reconnect
    $reuseOk = $false
    if (Load-DeviceState) {
        Write-Host "  $(Get-LangText '找到本地状态，正在校验...' 'Found saved state, validating...')"
        try {
            $sessionResp = Invoke-RestMethod -Method Get -Uri "$BaseUrl/devices/$script:DeviceId/session" -Headers (Get-Headers) -TimeoutSec 10
            if ($null -ne $sessionResp.is_bound) {
                $script:IsBound = [bool]$sessionResp.is_bound
            } else {
                $script:IsBound = $false
            }
            Write-Host "  $(Get-LangText '已重连' 'Reconnected'): $script:DeviceId"
            $reuseOk = $true
        } catch {
            $sc = Get-HttpStatusCode $_
            Write-Host "  $(Get-LangText '本地状态无效，正在重新注册...' 'Saved state invalid; re-registering...') (HTTP $sc)"
            if ($sc -ne 401 -and $sc -ne 403) {
                # Non-auth failure: clear recovery code to avoid sending stale code
                $script:RecoveryCode = $null
            }
            $script:DeviceId = $null
            $script:DeviceToken = $null
        }
    }
    if (-not $reuseOk) {
        Register-DeviceSelfService
        Save-DeviceState
    }

    # Language selection
    if ($script:DisplayLanguage) {
        Reload-UxStrings
    } else {
        Prompt-LanguageSelection
    }

    [void](Refresh-AccountSnapshot)
    Save-DeviceState
    Refresh-WindowTitle

    Show-ConnectedSummary

    if (-not $script:RunAsOwner) {
        Show-SecuritySummary
        Prompt-AimaShortcut

        $ownerHealthDetail = $null
        if ($reuseOk) {
            $ownerHealthDetail = Get-OwnerHealthDetail
        }
        if ($reuseOk -and $ownerHealthDetail) {
            Write-Host "  $(Get-LangText '凭据有效，但本地后台会话看起来已经失活，正在重启。' 'Saved credentials are valid, but the background session looks stale; restarting local owner.')" -ForegroundColor Yellow
            Write-OwnerLogLine -Level "WARN" -Message "launcher detected unhealthy owner during reconnect: $ownerHealthDetail"
        }
        if (-not (Start-OwnerProcess)) {
            if ($reuseOk) {
                Write-OwnerLogLine -Level "ERROR" -Message "launcher could not restart background owner during reconnect: $(if ($ownerHealthDetail) { $ownerHealthDetail } else { 'unknown reason' })"
                throw (Get-LangText '凭据有效，但无法重启本地后台设备会话。' 'Saved credentials are valid, but the background device session could not be restarted.')
            }
            throw (Get-LangText '无法启动后台设备会话。' 'Failed to start background device session.')
        }
        if ($reuseOk -and $ownerHealthDetail) {
            Write-OwnerLogLine -Level "INFO" -Message "launcher restarted background owner during reconnect: $ownerHealthDetail"
        }
        $script:AttachModeStarted = $true
        Show-AttachedUiLoop
        return
    }

    Ensure-RuntimeDirectory
    Write-SessionStatus -Phase "waiting" -Level "info" -Message $script:UxBackgroundSessionStarted
    Write-OwnerHeartbeat -Phase "waiting"

    $LastRenew = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $TokenRenewInterval = 86400
    $RetryInterval = 3
    $MaxRetryInterval = 15
    $AnsweredInteractions = New-Object System.Collections.ArrayList
    $NotifiedTasks = New-Object System.Collections.ArrayList
    if ($script:LastNotifiedTaskId) {
        $NotifiedTasks.Add($script:LastNotifiedTaskId) | Out-Null
    }
    $InteractionRetryAfter = @{}

    while ($true) {
        if (Test-Path -LiteralPath $script:DisconnectRequestFile) {
            break
        }
        if ($script:LocalCancelRequested) {
            $script:LocalCancelRequested = $false
            continue
        }

        Write-OwnerHeartbeat -Phase "polling"

        $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($Now - $LastRenew) -ge $TokenRenewInterval) {
            Renew-Token
            $LastRenew = $Now
        }

        try {
            $pollResponse = Invoke-RestMethod -Method Get `
                -Uri "$BaseUrl/devices/$script:DeviceId/poll?wait=10" `
                -Headers (Get-Headers) -TimeoutSec 15
        } catch {
            $statusCode = Get-HttpStatusCode $_
            if ($statusCode -eq 401 -or $statusCode -eq 403 -or $statusCode -eq 404) {
                Write-Host "[AIMA] $(Get-LangText '设备凭据无效或已过期，正在退出。' 'Device token invalid or expired; exiting.')"
                Write-Host "[AIMA] $(Get-LangText '轮询时凭据被拒绝，正在清理本地状态并停止。' 'Saved device credentials rejected during poll; clearing local state and stopping.') (HTTP $statusCode)"
                Clear-DeviceState
                break
            }
            Write-Host "[AIMA] $(Get-LangText '轮询失败，将在' 'Poll failed, retrying in') ${RetryInterval}s$(Get-LangText '后重试。' '.')"
            Start-Sleep -Seconds $RetryInterval
            $RetryInterval = [Math]::Min($RetryInterval * 2, $MaxRetryInterval)
            continue
        }
        $RetryInterval = 3

        if ($null -ne $pollResponse.is_bound) {
            $script:IsBound = [bool]$pollResponse.is_bound
        } else {
            $script:IsBound = $false
        }

        if ($pollResponse.command_id -and $pollResponse.command) {
            $currentCmdId = $pollResponse.command_id
            $currentCmd = $pollResponse.command
            $currentEnc = if ($pollResponse.command_encoding) { $pollResponse.command_encoding } else { "" }
            $currentTimeout = if ($pollResponse.command_timeout_seconds) { [int]$pollResponse.command_timeout_seconds } else { 300 }
            $currentIntent = if ($pollResponse.command_intent) { [string]$pollResponse.command_intent } else { "" }

            # Inner loop: chains inline commands returned by result submission
            while ($currentCmdId -and $currentCmd) {
                $submitResp = Invoke-DeviceCommand `
                    -CommandId $currentCmdId `
                    -RawCommand $currentCmd `
                    -CommandEncoding $currentEnc `
                    -CommandTimeout $currentTimeout `
                    -CommandIntent $currentIntent
                if ($script:LocalCancelRequested) {
                    break
                }
                # Check for inline next command in result response
                if ($submitResp -and $submitResp.next_command_id -and $submitResp.next_command) {
                    $currentCmdId = $submitResp.next_command_id
                    $currentCmd = $submitResp.next_command
                    $currentEnc = if ($submitResp.next_command_encoding) { $submitResp.next_command_encoding } else { "" }
                    $currentTimeout = if ($submitResp.next_command_timeout_seconds) { [int]$submitResp.next_command_timeout_seconds } else { 300 }
                    $currentIntent = if ($submitResp.next_command_intent) { [string]$submitResp.next_command_intent } else { "" }
                } else {
                    break
                }
            }

            if ($script:LocalCancelRequested) {
                $script:LocalCancelRequested = $false
                continue
            }
        }

        if ($pollResponse.interaction_id -and $pollResponse.question) {
            if (-not $AnsweredInteractions.Contains($pollResponse.interaction_id)) {
                if ($InteractionRetryAfter.ContainsKey($pollResponse.interaction_id)) {
                    $retryAt = [int64]$InteractionRetryAfter[$pollResponse.interaction_id]
                    if ($retryAt -gt $Now) {
                        $sleepSeconds = [Math]::Min([int]($retryAt - $Now), 5)
                        Start-Sleep -Seconds $sleepSeconds
                        continue
                    }
                    $InteractionRetryAfter.Remove($pollResponse.interaction_id) | Out-Null
                }

                $displayQuestion = ""
                if ($pollResponse.interaction_context -and $pollResponse.interaction_context.display_question) {
                    $displayQuestion = [string]$pollResponse.interaction_context.display_question
                }
                $handleStatus = Handle-Interaction `
                    -InteractionId $pollResponse.interaction_id `
                    -Question $pollResponse.question `
                    -InteractionType ([string]$pollResponse.interaction_type) `
                    -InteractionLevel ([string]$pollResponse.interaction_level) `
                    -InteractionPhase ([string]$pollResponse.interaction_phase) `
                    -DisplayQuestion $displayQuestion
                if ($handleStatus -eq 0) {
                    $InteractionRetryAfter.Remove($pollResponse.interaction_id) | Out-Null
                    $AnsweredInteractions.Add($pollResponse.interaction_id) | Out-Null
                } else {
                    $retryDelay = switch ($handleStatus) {
                        20 { 30 }
                        30 { 30 }
                        default { 10 }
                    }
                    $InteractionRetryAfter[$pollResponse.interaction_id] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $retryDelay
                }
            }
        }

        if ($pollResponse.notif_task_id -and $pollResponse.notif_task_status) {
            if ($script:ActiveTaskId -and $script:ActiveTaskId -ne $pollResponse.notif_task_id) {
                Start-Sleep -Seconds $PollIntervalSeconds
                continue
            }
            if (-not $NotifiedTasks.Contains($pollResponse.notif_task_id)) {
                $NotifiedTasks.Add($pollResponse.notif_task_id) | Out-Null
                $script:LastNotifiedTaskId = [string]$pollResponse.notif_task_id
                Save-DeviceState

                if ($script:ActiveTaskId -eq $pollResponse.notif_task_id) {
                    $script:ActiveTaskId = $null
                    $script:ConfirmedActiveTaskId = $null
                    $script:LastVisibleActiveTaskId = $null
                    $script:ActiveTaskLookupMisses = 0
                }

                Write-TaskCompletionFile `
                    -TaskId ([string]$pollResponse.notif_task_id) `
                    -TaskStatus ([string]$pollResponse.notif_task_status) `
                    -BudgetTasksRemaining $pollResponse.notif_budget_tasks_remaining `
                    -BudgetTasksTotal $pollResponse.notif_budget_tasks_total `
                    -BudgetUsdRemaining $pollResponse.notif_budget_usd_remaining `
                    -BudgetUsdTotal $pollResponse.notif_budget_usd_total `
                    -ReferralCode ([string]$pollResponse.notif_referral_code) `
                    -ShareText ([string]$pollResponse.notif_share_text) `
                    -TaskMessage ([string]$pollResponse.notif_task_message)
                if ([string]$pollResponse.notif_task_status -eq "succeeded") {
                    Write-SessionStatus -Phase "result" -Level "info" -Message (Get-LangText "任务已报告完成，请验证实际结果。" "Task reported complete. Please verify the result.")
                } else {
                    Write-SessionStatus -Phase "result" -Level "warning" -Message (Get-LangText "任务已结束，请查看结果。" "Task finished. Check the result.")
                }
                if (-not $script:RunAsOwner) {
                    Show-TaskCompletionCard `
                        -TaskStatus ([string]$pollResponse.notif_task_status) `
                        -BudgetTasksRemaining $pollResponse.notif_budget_tasks_remaining `
                        -BudgetTasksTotal $pollResponse.notif_budget_tasks_total `
                        -BudgetUsdRemaining $pollResponse.notif_budget_usd_remaining `
                        -BudgetUsdTotal $pollResponse.notif_budget_usd_total `
                        -ReferralCode ([string]$pollResponse.notif_referral_code) `
                        -ShareText ([string]$pollResponse.notif_share_text) `
                        -TaskMessage ([string]$pollResponse.notif_task_message) `
                        -BudgetWarning ([string]$pollResponse.budget_warning) `
                        -BudgetBindingIncentive ([string]$pollResponse.budget_binding_incentive)
                    Prompt-PostTaskFeedback -TaskId ([string]$pollResponse.notif_task_id)
                    Show-TaskMenu
                }
                continue
            }
        }
    }
} finally {
    if ($script:RunAsOwner) {
        $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $ownerPid = Get-OwnerPid
        if ($ownerPid -and $ownerPid -eq $currentPid) {
            Remove-Item -LiteralPath $script:OwnerPidFile -Force -ErrorAction SilentlyContinue
        }
        Set-Offline
    } elseif ($script:ExplicitDisconnectRequested) {
        # Request-ExplicitDisconnect already printed the final message.
    } elseif ($script:AttachModeStarted -and -not $script:AttachModeFailed) {
        Show-DetachMessage
    } elseif ($script:DeviceId -and $script:DeviceToken) {
        Set-Offline
    }
}
