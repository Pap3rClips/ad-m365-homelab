#Requires -Version 5.1

<#
.SYNOPSIS
    Prépare Intune pour l'enrôlement d'un poste Windows : inscription automatique MDM,
    stratégie de conformité, profils de configuration, affectation au groupe dynamique d'appareils.

.DESCRIPTION
    1. Inscription automatique MDM : portée « Tous » (API bêta ; consigne manuelle si refus)
    2. Stratégie de conformité Windows « WIN-Conformite-Base » :
       BitLocker, démarrage sécurisé, intégrité du code, TPM, chiffrement du stockage,
       pare-feu, antivirus/antispyware Defender en temps réel, version minimale de l'OS,
       mot de passe requis. Non-conformité -> appareil marqué non conforme après 24 h.
    3. Profil « WIN-Restrictions-Base » (restrictions d'appareil) : mot de passe, verrouillage
       après 10 min d'inactivité, Defender temps réel, stockage amovible bloqué
    4. Profil « WIN-BitLocker » (Endpoint Protection) : chiffrement du disque système
    5. Affectation au groupe SG-Dyn-Postes-Windows (règle device.deviceOSType -eq "Windows")

.EXAMPLE
    .\25-Configure-Intune.ps1 -WhatIf
    .\25-Configure-Intune.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabM365/LabM365.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$m365 = $config.M365
$intune = $m365.Intune

Connect-LabGraph -TenantDomain $m365.TenantDomain -Scopes @(
    'DeviceManagementConfiguration.ReadWrite.All', 'Group.Read.All',
    'Policy.Read.All', 'Policy.ReadWrite.MobilityManagement'
) | Out-Null

$targetGroup = Get-LabGraphGroup -DisplayName $intune.TargetGroup
if (-not $targetGroup) {
    throw "Groupe $($intune.TargetGroup) introuvable : lance d'abord 21-Provision-EntraIdentities.ps1"
}

function Set-IntuneAssignment {
    # Remplace les affectations de la stratégie par le groupe cible
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Collection, [string]$Id, [string]$Name, [string]$BodyKey)
    if ($PSCmdlet.ShouldProcess($Name, "Affecter à $($targetGroup.displayName)")) {
        Invoke-LabGraph -Method POST -Uri "v1.0/deviceManagement/$Collection/$Id/assign" -Body @{
            $BodyKey = @(@{
                    target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $targetGroup.id }
                })
        } | Out-Null
        Write-LabLog "$Name affectée à $($targetGroup.displayName)" -Level OK
    }
}

# =====================================================================================
# 1. Inscription automatique MDM
# =====================================================================================
$intuneMdmAppId = '0000000a-0000-0000-c000-000000000000'
try {
    $mdm = Invoke-LabGraph -Uri "beta/policies/mobileDeviceManagementPolicies/$intuneMdmAppId"
    if ($mdm.appliesTo -eq 'all') {
        Write-LabLog 'Inscription automatique MDM déjà active pour tous les utilisateurs' -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess('Microsoft Intune', 'Portée utilisateur MDM = Tous')) {
        Invoke-LabGraph -Method PATCH -Uri "beta/policies/mobileDeviceManagementPolicies/$intuneMdmAppId" -Body @{ appliesTo = 'all' } | Out-Null
        Write-LabLog "Inscription automatique MDM : portée « Tous » (était : $($mdm.appliesTo))" -Level OK
    }
}
catch {
    Write-LabLog "Portée MDM non modifiable par l'API ($(Get-LabGraphErrorMessage $_)). À faire à la main : Intune > Appareils > Inscription > Windows > Inscription automatique > Portée utilisateur MDM = Tous." -Level WARN
}

# =====================================================================================
# 2. Stratégie de conformité
# =====================================================================================
$compliance = @(Invoke-LabGraph -Uri 'v1.0/deviceManagement/deviceCompliancePolicies?$select=id,displayName') |
    Where-Object displayName -EQ $intune.CompliancePolicyName
if ($compliance) {
    Write-LabLog "Stratégie de conformité $($intune.CompliancePolicyName) déjà présente" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($intune.CompliancePolicyName, 'Créer la stratégie de conformité')) {
    try {
        $compliance = Invoke-LabGraph -Method POST -Uri 'v1.0/deviceManagement/deviceCompliancePolicies' -Body @{
            '@odata.type'            = '#microsoft.graph.windows10CompliancePolicy'
            displayName              = $intune.CompliancePolicyName
            description              = 'Socle de conformité des postes Windows du lab'
            passwordRequired         = $true
            passwordMinimumLength    = 8
            passwordRequiredType     = 'alphanumeric'
            osMinimumVersion         = $intune.MinOsVersion
            bitLockerEnabled         = $true
            secureBootEnabled        = $true
            codeIntegrityEnabled     = $true
            tpmRequired              = $true
            storageRequireEncryption = $true
            activeFirewallRequired   = $true
            defenderEnabled          = $true
            rtpEnabled               = $true
            antivirusRequired        = $true
            antiSpywareRequired      = $true
            scheduledActionsForRule  = @(@{
                    ruleName                      = 'PasswordRequired'
                    scheduledActionConfigurations = @(@{
                            actionType                = 'block'
                            gracePeriodHours          = 24
                            notificationTemplateId    = ''
                            notificationMessageCCList = @()
                        })
                })
        }
        Write-LabLog "Stratégie de conformité créée : $($intune.CompliancePolicyName)" -Level OK
    }
    catch {
        throw "Création de la stratégie de conformité refusée : $(Get-LabGraphErrorMessage $_)"
    }
}
if ($compliance) {
    Set-IntuneAssignment -Collection 'deviceCompliancePolicies' -Id $compliance.id -Name $intune.CompliancePolicyName -BodyKey 'assignments'
}

# =====================================================================================
# 3 et 4. Profils de configuration
# =====================================================================================
$profiles = @(
    @{
        displayName = $intune.ConfigProfileName
        body        = @{
            '@odata.type'                                  = '#microsoft.graph.windows10GeneralConfiguration'
            description                                    = 'Restrictions de base des postes Windows du lab'
            passwordRequired                               = $true
            passwordRequiredType                           = 'alphanumeric'
            passwordMinimumLength                          = 8
            passwordMinutesOfInactivityBeforeScreenTimeout = 10
            defenderRequireRealTimeMonitoring              = $true
            storageBlockRemovableStorage                   = $true
        }
    }
    @{
        displayName = 'WIN-BitLocker'
        body        = @{
            '@odata.type'                                = '#microsoft.graph.windows10EndpointProtectionConfiguration'
            description                                  = 'Chiffrement BitLocker du disque système'
            bitLockerEncryptDevice                       = $true
            bitLockerDisableWarningForOtherDiskEncryption = $true
            bitLockerAllowStandardUserEncryption         = $true
        }
    }
)

$existingProfiles = @(Invoke-LabGraph -Uri 'v1.0/deviceManagement/deviceConfigurations?$select=id,displayName')
foreach ($p in $profiles) {
    $current = $existingProfiles | Where-Object displayName -EQ $p.displayName
    if ($current) {
        Write-LabLog "Profil $($p.displayName) déjà présent" -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess($p.displayName, 'Créer le profil de configuration')) {
        $body = $p.body.Clone()
        $body.displayName = $p.displayName
        try {
            $current = Invoke-LabGraph -Method POST -Uri 'v1.0/deviceManagement/deviceConfigurations' -Body $body
            Write-LabLog "Profil créé : $($p.displayName)" -Level OK
        }
        catch {
            Write-LabLog "Profil $($p.displayName) refusé : $(Get-LabGraphErrorMessage $_)" -Level ERROR
            continue
        }
    }
    if ($current) {
        Set-IntuneAssignment -Collection 'deviceConfigurations' -Id $current.id -Name $p.displayName -BodyKey 'assignments'
    }
}

Write-LabLog 'Intune prêt. Enrôle maintenant le poste (docs/07-intune-enrolement.md) puis lance 26-Test-IntuneEnrollment.ps1 SUR ce poste.' -Level OK
