#Requires -Version 5.1

<#
.SYNOPSIS
    Vérifie, SUR une machine jointe (CLT01, CLT02, SRV01), que les GPO de sécurité sont
    réellement appliquées. Sert de preuve de bon fonctionnement (à capturer dans la doc).

.DESCRIPTION
    Lit l'état effectif de la machine (registre, services, politique) plutôt que la GPO :
    c'est ce qui compte côté sécurité. Lance d'abord « gpupdate /force » puis redémarre
    si des paramètres ordinateur viennent d'être modifiés.

.EXAMPLE
    .\11-Test-MemberHardening.ps1 | Format-Table -AutoSize
    .\11-Test-MemberHardening.ps1 -ExportPath C:\Temp\hardening-CLT01.csv
#>
[CmdletBinding()]
param(
    [string]$ExportPath
)

$ErrorActionPreference = 'Stop'

function Get-RegValue([string]$Path, [string]$Name) {
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}

$checks = [Collections.Generic.List[object]]::new()
function Test-Setting {
    param([string]$Category, [string]$Name, $Actual, $Expected)
    $checks.Add([pscustomobject]@{
            Categorie = $Category
            Controle  = $Name
            Attendu   = $Expected
            Constate  = if ($null -eq $Actual) { '(absent)' } else { $Actual }
            Resultat  = if ("$Actual" -eq "$Expected") { 'CONFORME' } else { 'ECART' }
        })
}

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
Test-Setting 'Domaine' 'Machine jointe au domaine' $cs.PartOfDomain $true
Test-Setting 'Domaine' 'Canal sécurisé avec le DC' (Test-ComputerSecureChannel -ErrorAction SilentlyContinue) $true

$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
Test-Setting 'Authentification' 'NTLMv2 uniquement (LmCompatibilityLevel)' (Get-RegValue $lsa 'LmCompatibilityLevel') 5
Test-Setting 'Authentification' 'Pas de hash LM (NoLMHash)' (Get-RegValue $lsa 'NoLMHash') 1
Test-Setting 'Authentification' 'LSA protégée (RunAsPPL)' (Get-RegValue $lsa 'RunAsPPL') 1
Test-Setting 'Authentification' 'WDigest désactivé' (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential') 0

$smb = Get-SmbServerConfiguration
Test-Setting 'SMB' 'SMBv1 serveur désactivé' $smb.EnableSMB1Protocol $false
Test-Setting 'SMB' 'Signature SMB serveur obligatoire' $smb.RequireSecuritySignature $true
Test-Setting 'SMB' 'Signature SMB client obligatoire' (Get-SmbClientConfiguration).RequireSecuritySignature $true

Test-Setting 'Réseau' 'LLMNR désactivé' (Get-RegValue 'HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast') 0
foreach ($p in Get-NetFirewallProfile) {
    Test-Setting 'Pare-feu' "Profil $($p.Name) actif" ([string]$p.Enabled) 'True'
}

$ps = 'HKLM:\Software\Policies\Microsoft\Windows\PowerShell'
Test-Setting 'Journalisation' 'PowerShell Script Block Logging' (Get-RegValue "$ps\ScriptBlockLogging" 'EnableScriptBlockLogging') 1
Test-Setting 'Journalisation' 'Transcription PowerShell' (Get-RegValue "$ps\Transcription" 'EnableTranscripting') 1
# Sous-catégorie « Ouvrir la session » par GUID ; 5e colonne = paramètre d'inclusion (libellés localisés)
$auditRow = & auditpol.exe /get /subcategory:'{0CCE9215-69AE-11D9-BED3-505054503030}' /r | Where-Object { $_ } | ConvertFrom-Csv | Select-Object -First 1
$audit = if ($auditRow) { @($auditRow.PSObject.Properties.Value)[4] } else { $null }
Test-Setting 'Journalisation' 'Audit des ouvertures de session (succès + échecs)' ([bool]($audit -match 'Success and Failure|Succès et échec')) $true

Test-Setting 'Session' 'Dernier utilisateur masqué' (Get-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'DontDisplayLastUserName') 1
Test-Setting 'Session' 'Bannière légale présente' ([bool](Get-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'LegalNoticeCaption')) $true

$guest = Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' }
Test-Setting 'Comptes' 'Compte Invité désactivé' $guest.Enabled $false

$lapsPolicy = Get-RegValue 'HKLM:\Software\Microsoft\Policies\LAPS' 'BackupDirectory'
Test-Setting 'LAPS' 'Sauvegarde du mot de passe local dans AD' $lapsPolicy 2

if ($cs.DomainRole -le 1) {
    # Postes uniquement
    Test-Setting 'Poste' 'Exécution automatique désactivée' (Get-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun') 255
    Test-Setting 'Poste' 'Stockage amovible bloqué' (Get-RegValue 'HKLM:\Software\Policies\Microsoft\Windows\RemovableStorageDevices' 'Deny_All') 1
    $admins = (Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue).Name -join ', '
    Test-Setting 'Poste' 'GG-Admins-Postes administrateur local' ([bool]($admins -match 'GG-Admins-Postes')) $true
}

$applied = & gpresult.exe /scope computer /r 2>$null | Select-String -Pattern 'GPO-' | ForEach-Object { $_.Line.Trim() }
Write-Host "GPO ordinateur appliquées : $($applied -join ', ')" -ForegroundColor Cyan

$ok = @($checks | Where-Object Resultat -EQ 'CONFORME').Count
Write-Host ("{0}/{1} contrôles conformes sur {2}" -f $ok, $checks.Count, $env:COMPUTERNAME) -ForegroundColor $(if ($ok -eq $checks.Count) { 'Green' } else { 'Yellow' })

if ($ExportPath) { $checks | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8 }
$checks
