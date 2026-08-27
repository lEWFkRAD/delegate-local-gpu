[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$delegateScript = Join-Path $PSScriptRoot 'delegate.ps1'
$temporaryBase = (Resolve-Path -LiteralPath $env:TEMP).Path
$temporaryRoot = Join-Path $temporaryBase ("delegate-local-gpu-test-" + (Get-Random))
$previousHelper = $env:CODEX_LOCAL_MODEL_HELPER

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $mockHelper = Join-Path $temporaryRoot 'local-model.ps1'
    @'
[CmdletBinding()]
param(
    [string]$Task,
    [string]$InputPath,
    [ValidateSet('onyx')][string]$Provider,
    [ValidateSet('triage', 'summarize', 'extract', 'draft', 'review')][string]$Purpose,
    [ValidateRange(16, 4096)][int]$MaxOutputTokens,
    [ValidateSet('low', 'medium', 'xhigh')][string]$ReasoningEffort,
    [ValidateRange(5, 1800)][int]$TimeoutSec,
    [switch]$AsJson
)
if ($Provider -ne 'onyx') {
    throw "Unexpected provider: $Provider"
}
if ($Task -eq '__EMPTY__') {
    return
}
if ($Task -eq '__MALFORMED__') {
    Write-Output 'not-json'
    return
}
$parts = @()
if ($PSBoundParameters.Keys -contains 'Task') {
    $parts += "task=$Task"
}
if ($PSBoundParameters.Keys -contains 'InputPath') {
    $parts += "file=$(Get-Content -LiteralPath $InputPath -Raw)"
}
[ordered]@{
    provider = if ($Task -eq '__WRONG_PROVIDER__') { 'unexpected' } else { $Provider }
    model = 'mock-local-model'
    purpose = $Purpose
    text = ($parts -join '|')
    elapsed_ms = 7
    usage = @{
        total_tokens = 11
        max_output_tokens = $MaxOutputTokens
        reasoning_effort = $ReasoningEffort
        timeout_seconds = $TimeoutSec
    }
} | ConvertTo-Json -Depth 5
'@ | Set-Content -LiteralPath $mockHelper -Encoding UTF8
    $env:CODEX_LOCAL_MODEL_HELPER = $mockHelper

    $publicParameters = (Get-Command -Name $delegateScript -CommandType ExternalScript).Parameters.Keys
    foreach ($forbidden in @('Provider', 'AllowForgePersonal', 'NoLog', 'AsJson', 'HelperPath')) {
        Assert-True ($publicParameters -notcontains $forbidden) "The wrapper exposes forbidden parameter '$forbidden'."
    }

    $selfTest = (& $delegateScript -SelfTest) | ConvertFrom-Json
    Assert-Equal $selfTest.status 'ok' 'Self-test status mismatch.'
    Assert-Equal $selfTest.provider 'onyx' 'Self-test provider mismatch.'
    Assert-Equal $selfTest.live_call $false 'Self-test must not make a live call.'

    $falseSelfTest = (& $delegateScript -SelfTest:$false) | ConvertFrom-Json
    Assert-Equal $falseSelfTest.status 'ok' 'False-valued self-test switch escaped its safe parameter set.'

    $incompatibleHelper = Join-Path $temporaryRoot 'incompatible-local-model.ps1'
    @'
[CmdletBinding()]
param(
    [string]$Task,
    [string]$InputPath,
    [ValidateSet('onyx')][string]$Provider,
    [ValidateSet('triage', 'summarize', 'extract', 'draft')][string]$Purpose,
    [ValidateRange(16, 4096)][int]$MaxOutputTokens,
    [ValidateSet('low', 'medium', 'xhigh')][string]$ReasoningEffort,
    [ValidateRange(5, 1800)][int]$TimeoutSec,
    [switch]$AsJson
)
'@ | Set-Content -LiteralPath $incompatibleHelper -Encoding UTF8
    $env:CODEX_LOCAL_MODEL_HELPER = $incompatibleHelper
    $incompatibleHelperFailed = $false
    try {
        & $delegateScript -SelfTest 2>$null | Out-Null
    }
    catch {
        $incompatibleHelperFailed = $true
    }
    Assert-True $incompatibleHelperFailed 'Self-test accepted a helper missing a required purpose.'
    $env:CODEX_LOCAL_MODEL_HELPER = $mockHelper

    $dryRun = (& $delegateScript -Task 'bounded evidence' -Purpose review -DryRun) | ConvertFrom-Json
    Assert-Equal $dryRun.status 'planned' 'Dry-run status mismatch.'
    Assert-Equal $dryRun.parameters.Provider 'onyx' 'Dry-run provider mismatch.'
    Assert-Equal $dryRun.parameters.AsJson $true 'Dry-run must force JSON output.'
    Assert-Equal $dryRun.live_call $false 'Dry-run must not make a live call.'
    Assert-Equal $dryRun.parameters.MaxOutputTokens 512 'Default output-token budget mismatch.'
    Assert-Equal $dryRun.parameters.ReasoningEffort 'low' 'Default reasoning effort mismatch.'
    Assert-Equal $dryRun.parameters.TimeoutSec 180 'Default timeout mismatch.'

    $falseDryRun = (& $delegateScript -Task 'bounded evidence' -DryRun:$false) | ConvertFrom-Json
    Assert-Equal $falseDryRun.status 'planned' 'False-valued dry-run switch escaped its safe parameter set.'

    $hostileTask = '''; throw "PWNED"; #'
    $taskRun = (& $delegateScript -Task $hostileTask -Purpose triage) | ConvertFrom-Json
    Assert-Equal $taskRun.status 'completed' 'Task status mismatch.'
    Assert-Equal $taskRun.provider 'onyx' 'Task provider mismatch.'
    Assert-Equal $taskRun.text "task=$hostileTask" 'Task text did not round-trip as one inert value.'

    $forwardedRun = (
        & $delegateScript `
            -Task 'explicit values' `
            -Purpose review `
            -MaxOutputTokens 1024 `
            -ReasoningEffort medium `
            -TimeoutSec 33
    ) | ConvertFrom-Json
    Assert-Equal $forwardedRun.purpose 'review' 'Purpose forwarding mismatch.'
    Assert-Equal $forwardedRun.usage.max_output_tokens 1024 'Output-token forwarding mismatch.'
    Assert-Equal $forwardedRun.usage.reasoning_effort 'medium' 'Reasoning-effort forwarding mismatch.'
    Assert-Equal $forwardedRun.usage.timeout_seconds 33 'Timeout forwarding mismatch.'

    $inputFile = Join-Path $temporaryRoot 'evidence.txt'
    Set-Content -LiteralPath $inputFile -Value 'file evidence' -NoNewline -Encoding UTF8
    $fileRun = (& $delegateScript -Task 'summarize it' -InputPath $inputFile -Purpose summarize) | ConvertFrom-Json
    Assert-Equal $fileRun.text 'task=summarize it|file=file evidence' 'Task-plus-file forwarding mismatch.'

    $missingInputFailed = $false
    try {
        & $delegateScript 2>$null | Out-Null
    }
    catch {
        $missingInputFailed = $true
    }
    Assert-True $missingInputFailed 'The wrapper accepted a run without a task or input file.'

    $providerOverrideFailed = $false
    try {
        & $delegateScript -Task 'x' -Provider onyx 2>$null | Out-Null
    }
    catch {
        $providerOverrideFailed = $true
    }
    Assert-True $providerOverrideFailed 'The wrapper accepted a caller-controlled provider.'

    foreach ($invalidResponseTask in @('__EMPTY__', '__MALFORMED__', '__WRONG_PROVIDER__')) {
        $invalidResponseFailed = $false
        try {
            & $delegateScript -Task $invalidResponseTask 2>$null | Out-Null
        }
        catch {
            $invalidResponseFailed = $true
        }
        Assert-True $invalidResponseFailed "The wrapper accepted invalid helper response '$invalidResponseTask'."
    }

    $scriptText = Get-Content -LiteralPath $delegateScript -Raw
    Assert-True (-not $scriptText.Contains('forge-personal')) 'The wrapper exposes the Forge provider.'

    Write-Output 'DELEGATE_LOCAL_GPU_TESTS_OK'
}
finally {
    if ($null -eq $previousHelper) {
        Remove-Item Env:CODEX_LOCAL_MODEL_HELPER -ErrorAction SilentlyContinue
    }
    else {
        $env:CODEX_LOCAL_MODEL_HELPER = $previousHelper
    }

    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $resolvedParent = Split-Path -Parent $resolvedTemporaryRoot
        if ($resolvedParent -ne $temporaryBase) {
            throw 'Refusing to remove a test directory outside the system temporary directory.'
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
