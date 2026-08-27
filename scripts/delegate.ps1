[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [Parameter(ParameterSetName = 'DryRun', Position = 0)]
    [string]$Task,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'DryRun')]
    [string]$InputPath,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'DryRun')]
    [ValidateSet('triage', 'summarize', 'extract', 'draft', 'review')]
    [string]$Purpose = 'triage',

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'DryRun')]
    [ValidateRange(16, 4096)]
    [int]$MaxOutputTokens = 512,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'DryRun')]
    [ValidateSet('low', 'medium', 'xhigh')]
    [string]$ReasoningEffort = 'low',

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'DryRun')]
    [ValidateRange(5, 1800)]
    [int]$TimeoutSec = 180,

    [Parameter(ParameterSetName = 'DryRun', Mandatory = $true)]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'SelfTest', Mandatory = $true)]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LocalModelHelper {
    $candidate = $env:CODEX_LOCAL_MODEL_HELPER
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = 'D:\BlueStone\scripts\local-model.ps1'
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "The approved local-model helper was not found at '$candidate'. Set CODEX_LOCAL_MODEL_HELPER to its absolute path."
    }

    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    if ($resolved -notlike '*.ps1') {
        throw "The local-model helper must be a PowerShell script: '$resolved'."
    }
    return $resolved
}

$helperPath = Resolve-LocalModelHelper

if ($PSCmdlet.ParameterSetName -eq 'SelfTest') {
    $helper = Get-Command -Name $helperPath -CommandType ExternalScript -ErrorAction Stop
    $requiredParameters = @(
        'Task',
        'InputPath',
        'Provider',
        'Purpose',
        'MaxOutputTokens',
        'ReasoningEffort',
        'TimeoutSec',
        'AsJson'
    )
    foreach ($name in $requiredParameters) {
        if ($helper.Parameters.Keys -notcontains $name) {
            throw "The local-model helper is missing required parameter '$name'."
        }
    }

    $expectedTypes = [ordered]@{
        Task = 'String'
        InputPath = 'String'
        Provider = 'String'
        Purpose = 'String'
        MaxOutputTokens = 'Int32'
        ReasoningEffort = 'String'
        TimeoutSec = 'Int32'
        AsJson = 'SwitchParameter'
    }
    foreach ($name in $expectedTypes.Keys) {
        if ($helper.Parameters[$name].ParameterType.Name -ne $expectedTypes[$name]) {
            throw "The local-model helper parameter '$name' has incompatible type '$($helper.Parameters[$name].ParameterType.Name)'."
        }
    }

    $requiredValues = [ordered]@{
        Provider = @('onyx')
        Purpose = @('triage', 'summarize', 'extract', 'draft', 'review')
        ReasoningEffort = @('low', 'medium', 'xhigh')
    }
    foreach ($name in $requiredValues.Keys) {
        $advertisedValues = @(
            $helper.Parameters[$name].Attributes |
                Where-Object { $_.PSObject.Properties.Name -contains 'ValidValues' } |
                ForEach-Object { $_.ValidValues }
        )
        foreach ($value in $requiredValues[$name]) {
            if ($advertisedValues -notcontains $value) {
                throw "The local-model helper parameter '$name' does not advertise required value '$value'."
            }
        }
    }

    $requiredRanges = [ordered]@{
        MaxOutputTokens = [ordered]@{ Minimum = 16; Maximum = 4096 }
        TimeoutSec = [ordered]@{ Minimum = 5; Maximum = 1800 }
    }
    foreach ($name in $requiredRanges.Keys) {
        $compatibleRangeFound = $false
        foreach ($attribute in $helper.Parameters[$name].Attributes) {
            if (
                $attribute.PSObject.Properties.Name -contains 'MinRange' -and
                $attribute.MinRange -le $requiredRanges[$name].Minimum -and
                $attribute.MaxRange -ge $requiredRanges[$name].Maximum
            ) {
                $compatibleRangeFound = $true
            }
        }
        if (-not $compatibleRangeFound) {
            throw "The local-model helper parameter '$name' does not support the required range."
        }
    }

    [ordered]@{
        schema_version = 1
        status = 'ok'
        live_call = $false
        provider = 'onyx'
        helper_path = $helperPath
        contract_parameters = $requiredParameters
        contract_values = $requiredValues
        contract_ranges = $requiredRanges
    } | ConvertTo-Json -Depth 5
    return
}

if ([string]::IsNullOrWhiteSpace($Task) -and [string]::IsNullOrWhiteSpace($InputPath)) {
    throw 'Provide -Task, -InputPath, or both.'
}

$resolvedInput = $null
if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Input file not found: '$InputPath'."
    }
    $resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
}

$forward = [ordered]@{
    Purpose = $Purpose
    MaxOutputTokens = $MaxOutputTokens
    ReasoningEffort = $ReasoningEffort
    TimeoutSec = $TimeoutSec
}
if ($PSBoundParameters.Keys -contains 'Task') {
    $forward['Task'] = $Task
}
if ($null -ne $resolvedInput) {
    $forward['InputPath'] = $resolvedInput
}

if ($PSCmdlet.ParameterSetName -eq 'DryRun') {
    [ordered]@{
        schema_version = 1
        status = 'planned'
        live_call = $false
        helper_path = $helperPath
        parameters = [ordered]@{
            Provider = 'onyx'
            Purpose = $Purpose
            InputPath = $resolvedInput
            TaskCharacters = if ($null -eq $Task) { 0 } else { $Task.Length }
            MaxOutputTokens = $MaxOutputTokens
            ReasoningEffort = $ReasoningEffort
            TimeoutSec = $TimeoutSec
            AsJson = $true
        }
    } | ConvertTo-Json -Depth 5
    return
}

$rawResponse = @(
    & $helperPath -Provider 'onyx' @forward -AsJson
) -join [Environment]::NewLine
if ([string]::IsNullOrWhiteSpace($rawResponse)) {
    throw 'The local-model helper returned an empty response.'
}

try {
    $response = $rawResponse | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "The local-model helper returned invalid JSON: $($_.Exception.Message)"
}

if (
    $null -eq $response -or
    $response.PSObject.Properties.Name -notcontains 'provider' -or
    $response.provider -ne 'onyx'
) {
    throw 'The local-model helper returned an unexpected provider.'
}
if (
    $response.PSObject.Properties.Name -notcontains 'text' -or
    [string]::IsNullOrWhiteSpace([string]$response.text)
) {
    throw 'The local-model helper returned no worker text.'
}

[ordered]@{
    schema_version = 1
    status = 'completed'
    live_call = $true
    provider = 'onyx'
    model = if ($response.PSObject.Properties.Name -contains 'model') { $response.model } else { $null }
    purpose = $Purpose
    text = $response.text
    elapsed_ms = if ($response.PSObject.Properties.Name -contains 'elapsed_ms') { $response.elapsed_ms } else { $null }
    usage = if ($response.PSObject.Properties.Name -contains 'usage') { $response.usage } else { $null }
} | ConvertTo-Json -Depth 10
