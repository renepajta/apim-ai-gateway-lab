# APIM AI Gateway Lab - PowerShell wrapper around tests/test_gateway.py.
#
# Usage:
#   .\tests\test.ps1 -Scenario baseline
#   .\tests\test.ps1 -Scenario all
#
# Scenarios mirror docs/demo-script.md and tests/test_gateway.py:
#   baseline | timeout-fast | timeout-batch | cb | cancel | stream |
#   sticky | cache | safety | jailbreak | external | mcp | all

[CmdletBinding()]
param(
    [ValidateSet('baseline','timeout-fast','timeout-batch','cb','cancel','stream','sticky','cache','safety','jailbreak','external','mcp','all')]
    [string]$Scenario = 'baseline'
)

$ErrorActionPreference = 'Continue'

# Force UTF-8 so unicode arrows in banners don't crash on cp1252 consoles.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
try { chcp 65001 | Out-Null } catch { }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$envFile = Join-Path $repoRoot '.demo.env'
if (-not (Test-Path $envFile)) { throw "Run scripts/deploy.ps1 first (missing $envFile)" }

$envMap = @{}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^(\w+)=(.*)$') { $envMap[$Matches[1]] = $Matches[2].Trim() }
}

$py = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command py -ErrorAction SilentlyContinue)
if (-not $py) { throw "python not found on PATH" }

Write-Host "# Gateway: $($envMap['GATEWAY_URL'])" -ForegroundColor DarkGray
Write-Host "# Scenario: $Scenario" -ForegroundColor DarkGray

& $py.Source (Join-Path $here 'test_gateway.py') --scenario $Scenario
exit $LASTEXITCODE
