[CmdletBinding()]
param([string]$ResourceGroup = 'rg-aigw-lab', [switch]$Yes)
if (-not $Yes) {
    $ans = Read-Host "Delete RG '$ResourceGroup' and ALL resources? (type DELETE)"
    if ($ans -ne 'DELETE') { Write-Host 'Aborted.'; return }
}
Write-Host "Deleting RG $ResourceGroup (no-wait)..."
az group delete --name $ResourceGroup --yes --no-wait
Write-Host "Issued. Track with: az group show -n $ResourceGroup -o table"
