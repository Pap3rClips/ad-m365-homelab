#Requires -Version 5.1
#Requires -Modules ActiveDirectory, GroupPolicy

<#
.SYNOPSIS
    Crée et lie les GPO de sécurité du lab, configure Windows LAPS et le mappage des lecteurs.

.DESCRIPTION
    GPO créées (toutes préfixées pour être repérables dans la console GPMC) :

    GPO-SEC-Ordinateurs-Baseline   -> OU Ordinateurs (postes + serveurs)
        Options de sécurité : NTLMv2 uniquement, pas de hash LM, signature SMB obligatoire,
        anonymes restreints, dernier utilisateur masqué, verrouillage après 15 min d'inactivité,
        bannière légale ; compte Invité désactivé ; stratégie d'audit (connexions, comptes,
        changements de stratégie) ; SMBv1 désactivé ; WDigest désactivé ; LSA protégée ;
        journalisation PowerShell (blocs de script + transcription) ; pare-feu actif sur
        les trois profils.

    GPO-SEC-Postes-Durcissement    -> OU Ordinateurs/Postes
        LLMNR désactivé, exécution automatique désactivée, stockage amovible bloqué,
        protection PUA de Defender, GG-Admins-Postes ajouté aux Administrateurs locaux.

    GPO-SEC-LAPS                   -> OU Ordinateurs
        Windows LAPS : mot de passe de l'administrateur local unique, sauvegardé (chiffré) dans AD.

    GPO-USR-Verrouillage-Ecran     -> OU Utilisateurs
        Écran de veille protégé par mot de passe après 10 minutes.

    GPO-USR-Lecteurs-Reseau        -> OU Utilisateurs
        P: \\SRV01\Commun pour tous, K: \\SRV01\Comptabilite ciblé par groupe.

.EXAMPLE
    .\08-Configure-SecurityGPOs.ps1 -WhatIf
    .\08-Configure-SecurityGPOs.ps1
    # Sur un client : gpupdate /force puis gpresult /h C:\gpresult.html
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [switch]$SkipLaps
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabGpo/LabGpo.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$fqdn   = $config.Domain.FQDN
$rootOU = $config.Domain.RootOU
$nb     = $config.Domain.NetBIOS

$ouComputers = ConvertTo-LabOUPath -RelativePath 'Ordinateurs'        -RootOU $rootOU -Fqdn $fqdn
$ouWorkst    = ConvertTo-LabOUPath -RelativePath 'Ordinateurs/Postes' -RootOU $rootOU -Fqdn $fqdn
$ouUsers     = ConvertTo-LabOUPath -RelativePath 'Utilisateurs'       -RootOU $rootOU -Fqdn $fqdn

function Set-Reg {
    # Raccourci vers Set-GPRegistryValue (Registry.pol, idempotent par nature)
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Gpo, [string]$Key, [string]$Name, [ValidateSet('DWord', 'String', 'ExpandString')][string]$Type, $Value)
    if ($PSCmdlet.ShouldProcess($Gpo, "$Key\$Name = $Value")) {
        Set-GPRegistryValue -Name $Gpo -Key $Key -ValueName $Name -Type $Type -Value $Value | Out-Null
    }
}

function Publish-Gpo {
    param([string]$Name, [string]$Comment, [string[]]$Targets)
    $gpo = Get-LabGpo -Name $Name -Comment $Comment
    foreach ($t in $Targets) {
        if (Set-LabGpoLink -Name $Name -Target $t) { Write-LabLog "$Name liée à $t" -Level OK }
    }
    $gpo
}

# =====================================================================================
# 1. Baseline ordinateurs
# =====================================================================================
$name = 'GPO-SEC-Ordinateurs-Baseline'
$gpo = Publish-Gpo -Name $name -Comment 'Socle de sécurité commun aux postes et serveurs' -Targets $ouComputers

$banner = $config.LogonBanner
$template = [ordered]@{
    'System Access' = [ordered]@{
        EnableGuestAccount = 0
    }
    # 0 = aucun, 1 = succès, 2 = échecs, 3 = succès + échecs
    'Event Audit' = [ordered]@{
        AuditSystemEvents    = 3
        AuditLogonEvents     = 3
        AuditAccountLogon    = 3
        AuditAccountManage   = 3
        AuditPolicyChange    = 3
        AuditPrivilegeUse    = 2
        AuditObjectAccess    = 2
        AuditProcessTracking = 0
        AuditDSAccess        = 0
    }
    # Format : chemin=type,valeur (4 = REG_DWORD, 1 = REG_SZ, 7 = REG_MULTI_SZ)
    'Registry Values' = [ordered]@{
        'MACHINE\System\CurrentControlSet\Control\Lsa\LmCompatibilityLevel'                         = '4,5'
        'MACHINE\System\CurrentControlSet\Control\Lsa\NoLMHash'                                     = '4,1'
        'MACHINE\System\CurrentControlSet\Control\Lsa\RestrictAnonymous'                            = '4,1'
        'MACHINE\System\CurrentControlSet\Control\Lsa\RestrictAnonymousSAM'                         = '4,1'
        'MACHINE\System\CurrentControlSet\Services\LanmanServer\Parameters\RequireSecuritySignature'      = '4,1'
        'MACHINE\System\CurrentControlSet\Services\LanmanServer\Parameters\EnableSecuritySignature'       = '4,1'
        'MACHINE\System\CurrentControlSet\Services\LanmanWorkstation\Parameters\RequireSecuritySignature' = '4,1'
        'MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\DontDisplayLastUserName' = '4,1'
        'MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs'   = '4,900'
        'MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\LegalNoticeCaption'      = ('1,"{0}"' -f $banner.Caption)
        'MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\LegalNoticeText'         = ('7,{0}' -f $banner.Text)
    }
}
if (-not $gpo) {
    Write-LabLog "$name : GPO inexistante (mode -WhatIf), modèle de sécurité non simulé" -Level SKIP
}
elseif (Set-LabGpoSecurityTemplate -Gpo $gpo -Sections $template) {
    Write-LabLog "$name : options de sécurité et audit écrits (GptTmpl.inf)" -Level OK
}
else {
    Write-LabLog "$name : modèle de sécurité déjà à jour" -Level SKIP
}

$hklm = 'HKLM\SYSTEM\CurrentControlSet'
Set-Reg $name "$hklm\Services\LanmanServer\Parameters" 'SMB1' DWord 0
Set-Reg $name "$hklm\Control\SecurityProviders\WDigest" 'UseLogonCredential' DWord 0
Set-Reg $name "$hklm\Control\Lsa" 'RunAsPPL' DWord 1
$ps = 'HKLM\Software\Policies\Microsoft\Windows\PowerShell'
Set-Reg $name "$ps\ScriptBlockLogging" 'EnableScriptBlockLogging' DWord 1
Set-Reg $name "$ps\Transcription" 'EnableTranscripting' DWord 1
Set-Reg $name "$ps\Transcription" 'EnableInvocationHeader' DWord 1
Set-Reg $name "$ps\Transcription" 'OutputDirectory' String 'C:\ProgramData\PSTranscripts'
foreach ($fwProfile in 'DomainProfile', 'PrivateProfile', 'PublicProfile') {
    Set-Reg $name "HKLM\Software\Policies\Microsoft\WindowsFirewall\$fwProfile" 'EnableFirewall' DWord 1
    Set-Reg $name "HKLM\Software\Policies\Microsoft\WindowsFirewall\$fwProfile" 'DefaultInboundAction' DWord 1
}
Write-LabLog "$name : SMBv1, WDigest, LSA, journalisation PowerShell, pare-feu" -Level OK

# =====================================================================================
# 2. Durcissement des postes
# =====================================================================================
$name = 'GPO-SEC-Postes-Durcissement'
$gpo = Publish-Gpo -Name $name -Comment 'Réduction de surface d''attaque des postes de travail' -Targets $ouWorkst

Set-Reg $name 'HKLM\Software\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' DWord 0
Set-Reg $name 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' DWord 255
Set-Reg $name 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutorun' DWord 1
Set-Reg $name 'HKLM\Software\Policies\Microsoft\Windows\RemovableStorageDevices' 'Deny_All' DWord 1
Set-Reg $name 'HKLM\Software\Policies\Microsoft\Windows Defender' 'PUAProtection' DWord 1
Write-LabLog "$name : LLMNR, exécution automatique, stockage amovible, Defender PUA" -Level OK

# GG-Admins-Postes -> Administrateurs locaux (forme « Membre de » : ajoute sans écraser le groupe)
$adminsSid = (Get-ADGroup -Identity 'GG-Admins-Postes').SID.Value
$membership = [ordered]@{
    'Group Membership' = [ordered]@{
        "*${adminsSid}__Memberof" = '*S-1-5-32-544'
    }
}
if ($gpo -and (Set-LabGpoSecurityTemplate -Gpo $gpo -Sections $membership)) {
    Write-LabLog "$name : GG-Admins-Postes membre des Administrateurs locaux" -Level OK
}

# =====================================================================================
# 3. Windows LAPS
# =====================================================================================
if (-not $SkipLaps) {
    if (-not (Get-Command -Name Update-LapsADSchema -ErrorAction SilentlyContinue)) {
        Write-LabLog 'Module LAPS absent : installe les mises à jour cumulatives d''avril 2023 ou plus récentes, ou relance avec -SkipLaps' -Level WARN
    }
    else {
        if ($PSCmdlet.ShouldProcess('Schéma AD', 'Update-LapsADSchema')) {
            Update-LapsADSchema -Confirm:$false
            Write-LabLog 'Schéma AD étendu pour Windows LAPS' -Level OK
        }
        if ($PSCmdlet.ShouldProcess($ouComputers, 'Set-LapsADComputerSelfPermission')) {
            Set-LapsADComputerSelfPermission -Identity $ouComputers | Out-Null
            Write-LabLog "Les ordinateurs de $ouComputers peuvent écrire leur mot de passe LAPS" -Level OK
        }

        $name = 'GPO-SEC-LAPS'
        Publish-Gpo -Name $name -Comment 'Windows LAPS - mot de passe administrateur local unique' -Targets $ouComputers | Out-Null
        $laps = 'HKLM\Software\Microsoft\Policies\LAPS'
        Set-Reg $name $laps 'BackupDirectory' DWord 2                       # 2 = Active Directory
        Set-Reg $name $laps 'PasswordComplexity' DWord 4                    # maj + min + chiffres + spéciaux
        Set-Reg $name $laps 'PasswordLength' DWord $config.Laps.PasswordLength
        Set-Reg $name $laps 'PasswordAgeDays' DWord $config.Laps.PasswordAgeDays
        Set-Reg $name $laps 'ADPasswordEncryptionEnabled' DWord ([int][bool]$config.Laps.EncryptPasswords)
        Set-Reg $name $laps 'PostAuthenticationActions' DWord 3             # réinitialiser + déconnecter après usage
        Set-Reg $name $laps 'PostAuthenticationResetDelay' DWord 8
        Write-LabLog "$name : $($config.Laps.PasswordLength) caractères, rotation $($config.Laps.PasswordAgeDays) j, chiffré dans AD" -Level OK
    }
}

# =====================================================================================
# 4. Verrouillage de session (configuration utilisateur)
# =====================================================================================
$name = 'GPO-USR-Verrouillage-Ecran'
Publish-Gpo -Name $name -Comment 'Écran de veille protégé après 10 minutes' -Targets $ouUsers | Out-Null
$desk = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
Set-Reg $name $desk 'ScreenSaveActive' String '1'
Set-Reg $name $desk 'ScreenSaverIsSecure' String '1'
Set-Reg $name $desk 'ScreenSaveTimeOut' String '600'
Write-LabLog "$name : verrouillage après 600 s" -Level OK

# =====================================================================================
# 5. Lecteurs réseau (préférences)
# =====================================================================================
$name = 'GPO-USR-Lecteurs-Reseau'
$gpo = Publish-Gpo -Name $name -Comment 'Mappage des partages de SRV01 selon le service' -Targets $ouUsers
$drives = foreach ($share in $config.FileShares) {
    [pscustomobject]@{
        Letter = $share.DriveLetter
        Path   = "\\$($config.FileServer)\$($share.Name)"
        Label  = $share.Name
        Groups = @($share.DriveGroups | ForEach-Object {
                @{ Name = "$nb\$_"; Sid = (Get-ADGroup -Identity $_).SID.Value }
            })
    }
}
if ($gpo) { Set-LabGpoDriveMap -Gpo $gpo -Drives $drives }
Write-LabLog "$name : $(($drives | ForEach-Object { "$($_.Letter): $($_.Path)" }) -join ', ')" -Level OK

# =====================================================================================
# Rapport
# =====================================================================================
$reportDir = Join-Path -Path (Get-LabRoot) -ChildPath 'output/gpo'
New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
Get-GPO -All | Where-Object DisplayName -Like 'GPO-*' | ForEach-Object {
    Get-GPOReport -Guid $_.Id -ReportType Html -Path (Join-Path -Path $reportDir -ChildPath "$($_.DisplayName).html")
}
Write-LabLog "Rapports HTML des GPO : output/gpo/. Sur un client : gpupdate /force puis gpresult /r" -Level OK
