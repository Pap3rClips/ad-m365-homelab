#Requires -Version 5.1

<#
.SYNOPSIS
    Vérifie, SUR le poste enrôlé (CLT-CLOUD01), la jonction Entra ID et l'inscription Intune,
    force une synchronisation et produit un rapport de diagnostic MDM.

.DESCRIPTION
    - dsregcmd /status : AzureAdJoined, nom du tenant, URL MDM, PRT obtenu
    - Inscriptions MDM dans le registre (fournisseur « MS DM Server »)
    - Lancement de la tâche planifiée de synchronisation Intune
    - Rapport MdmDiagnosticsTool (HTML + CAB) pour la documentation
    - Optionnel : hash matériel Autopilot (-CollectAutopilotHash)

.EXAMPLE
    .\26-Test-IntuneEnrollment.ps1
    .\26-Test-IntuneEnrollment.ps1 -OutputDirectory C:\Temp\Intune -CollectAutopilotHash
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path -Path $env:PUBLIC -ChildPath 'Documents\IntuneDiag'),
    [switch]$CollectAutopilotHash
)

$ErrorActionPreference = 'Stop'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

# --- dsregcmd ------------------------------------------------------------------------------
$dsreg = @{}
& dsregcmd.exe /status | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z]+)\s*:\s*(.+?)\s*$') { $dsreg[$Matches[1]] = $Matches[2] }
}

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    $checks.Add([pscustomobject]@{ Controle = $Name; Resultat = if ($Ok) { 'OK' } else { 'KO' }; Detail = $Detail })
}

Add-Check 'Joint à Entra ID (AzureAdJoined)' ($dsreg['AzureAdJoined'] -eq 'YES') $dsreg['AzureAdJoined']
Add-Check 'Tenant' ([bool]$dsreg['TenantName']) $dsreg['TenantName']
Add-Check 'URL MDM présente' ([bool]$dsreg['MdmUrl']) $dsreg['MdmUrl']
Add-Check 'Jeton PRT obtenu (SSO)' ($dsreg['AzureAdPrt'] -eq 'YES') $dsreg['AzureAdPrt']
Add-Check 'Non joint à un domaine AD (poste cloud)' ($dsreg['DomainJoined'] -eq 'NO') $dsreg['DomainJoined']

# --- Inscription MDM ---------------------------------------------------------------------------
$enrollments = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty -Path $_.PSPath } |
    Where-Object { $_.PSObject.Properties.Name -contains 'ProviderID' -and $_.ProviderID -eq 'MS DM Server' }
$enrollment = $enrollments | Select-Object -First 1
Add-Check 'Inscription MDM Intune' ([bool]$enrollment) $(if ($enrollment) { "UPN : $($enrollment.UPN) ; GUID : $($enrollment.PSChildName)" } else { 'aucune' })

# --- Synchronisation ------------------------------------------------------------------------------
if ($enrollment) {
    $taskPath = "\Microsoft\Windows\EnterpriseMgmt\$($enrollment.PSChildName)\"
    $syncTask = Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
        Where-Object TaskName -Like 'Schedule #3 created by enrollment client*' | Select-Object -First 1
    if ($syncTask) {
        Start-ScheduledTask -TaskPath $taskPath -TaskName $syncTask.TaskName
        Add-Check 'Synchronisation Intune déclenchée' $true $syncTask.TaskName
    }
    else {
        Add-Check 'Synchronisation Intune déclenchée' $false 'Tâche introuvable : Paramètres > Comptes > Accès Professionnel > Info > Synchroniser'
    }
}

# --- BitLocker (attendu par la conformité) ------------------------------------------------------------
$bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
Add-Check 'BitLocker sur le disque système' ($bl -and $bl.ProtectionStatus -eq 'On') $(if ($bl) { "$($bl.VolumeStatus), protection $($bl.ProtectionStatus)" } else { 'non disponible' })
$sb = try { Confirm-SecureBootUEFI } catch { $false }
Add-Check 'Démarrage sécurisé' ([bool]$sb) "$sb"
$tpm = Get-Tpm -ErrorAction SilentlyContinue
Add-Check 'TPM prêt' ($tpm -and $tpm.TpmReady) $(if ($tpm) { "Présent : $($tpm.TpmPresent), prêt : $($tpm.TpmReady)" } else { 'absent (active le vTPM de la VM)' })

# --- Diagnostic MDM ----------------------------------------------------------------------------------
$diagDir = Join-Path -Path $OutputDirectory -ChildPath 'MDMDiag'
& MdmDiagnosticsTool.exe -out $diagDir | Out-Null
Add-Check 'Rapport MdmDiagnosticsTool' (Test-Path -Path (Join-Path -Path $diagDir -ChildPath 'MDMDiagReport.html')) $diagDir

# --- Autopilot (facultatif) -------------------------------------------------------------------------
if ($CollectAutopilotHash) {
    if (-not (Get-Command -Name Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue)) {
        Install-Script -Name Get-WindowsAutopilotInfo -Scope CurrentUser -Force
    }
    $hashFile = Join-Path -Path $OutputDirectory -ChildPath "autopilot-$env:COMPUTERNAME.csv"
    & Get-WindowsAutopilotInfo -OutputFile $hashFile
    Add-Check 'Hash Autopilot exporté' (Test-Path -Path $hashFile) $hashFile
}

$checks | Export-Csv -Path (Join-Path -Path $OutputDirectory -ChildPath 'enrollment-checks.csv') -NoTypeInformation -Encoding UTF8
$checks | Format-Table -AutoSize
$ko = @($checks | Where-Object Resultat -EQ 'KO').Count
Write-Host ("{0} contrôle(s) en échec. Résultats et diagnostic : {1}" -f $ko, $OutputDirectory) -ForegroundColor $(if ($ko) { 'Yellow' } else { 'Green' })
