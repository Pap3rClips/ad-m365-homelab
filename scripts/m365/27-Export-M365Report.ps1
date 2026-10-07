#Requires -Version 5.1

<#
.SYNOPSIS
    Exporte l'état du tenant (Entra ID, MFA, accès conditionnel, Intune, Exchange) en HTML + CSV,
    et les stratégies CA en JSON. Preuves de réalisation de la partie Microsoft 365.

.DESCRIPTION
    Sortie : output/evidence/m365-AAAAMMJJ-HHMM/
    Lecture seule : aucune modification du tenant.

.EXAMPLE
    .\27-Export-M365Report.ps1
    .\27-Export-M365Report.ps1 -IncludeExchange
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$IncludeExchange
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabM365/LabM365.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$m365 = $config.M365

$org = Connect-LabGraph -TenantDomain $m365.TenantDomain -Scopes @(
    'Directory.Read.All', 'Policy.Read.All', 'AuditLog.Read.All', 'RoleManagement.Read.Directory',
    'DeviceManagementManagedDevices.Read.All', 'DeviceManagementConfiguration.Read.All'
)

$outDir = Join-Path -Path (Get-LabRoot) -ChildPath ('output/evidence/m365-{0:yyyyMMdd-HHmm}' -f (Get-Date))
New-Item -Path $outDir -ItemType Directory -Force | Out-Null
$sections = [Collections.Generic.List[object]]::new()
function Add-Section([string]$Title, [string]$CsvName, [object[]]$Data, [string]$Note = '') {
    $sections.Add(@{ Title = $Title; CsvName = $CsvName; Data = $Data; Note = $Note })
}
function Get-Safe([scriptblock]$Block, [string]$What) {
    try { & $Block } catch { Write-LabLog "$What : $(Get-LabGraphErrorMessage $_)" -Level WARN; @() }
}

Write-LabLog 'Collecte Entra ID...'

# --- Licences ----------------------------------------------------------------------------------------
$skus = @(Invoke-LabGraph -Uri 'v1.0/subscribedSkus')
$skuNames = @{}
foreach ($s in $skus) { $skuNames[$s.skuId] = $s.skuPartNumber }
Add-Section 'Licences du tenant' 'licenses' @($skus | ForEach-Object {
        [pscustomobject]@{ SKU = $_.skuPartNumber; Achetees = $_.prepaidUnits.enabled; Consommees = $_.consumedUnits; Statut = $_.capabilityStatus }
    }) "Tenant : $($org.displayName)"

# --- Utilisateurs ----------------------------------------------------------------------------------------
$users = @(Invoke-LabGraph -Uri 'v1.0/users?$select=id,displayName,userPrincipalName,department,jobTitle,accountEnabled,assignedLicenses,userType,createdDateTime&$top=999')
Add-Section 'Utilisateurs Entra ID' 'users' @($users | Sort-Object department, userPrincipalName | ForEach-Object {
        [pscustomobject]@{
            UPN = $_.userPrincipalName; Nom = $_.displayName; Service = $_.department; Poste = $_.jobTitle
            Actif = $_.accountEnabled; Type = $_.userType
            Licences = (@($_.assignedLicenses | ForEach-Object { $skuNames[$_.skuId] }) -join ', ')
        }
    })

# --- Groupes ------------------------------------------------------------------------------------------------
$groups = @(Invoke-LabGraph -Uri 'v1.0/groups?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,membershipRule,assignedLicenses&$top=999')
Add-Section 'Groupes' 'groups' @($groups | Sort-Object displayName | ForEach-Object {
        $type = if ($_.groupTypes -contains 'Unified') { 'Microsoft 365' } elseif ($_.securityEnabled) { 'Sécurité' } else { 'Distribution' }
        [pscustomobject]@{
            Groupe   = $_.displayName
            Type     = $type
            Dynamique = ($_.groupTypes -contains 'DynamicMembership')
            Regle    = $_.membershipRule
            Membres  = @(Invoke-LabGraph -Uri "v1.0/groups/$($_.id)/members?`$select=id").Count
            Licences = (@($_.assignedLicenses | ForEach-Object { $skuNames[$_.skuId] }) -join ', ')
        }
    })

# --- Rôles à privilèges -----------------------------------------------------------------------------------------
$roleDefs = @{}
Invoke-LabGraph -Uri 'v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName' | ForEach-Object { $roleDefs[$_.id] = $_.displayName }
$privileged = @(Get-Safe -What 'Rôles' -Block {
        Invoke-LabGraph -Uri 'v1.0/roleManagement/directory/roleAssignments?$expand=principal' | ForEach-Object {
            [pscustomobject]@{
                Role      = $roleDefs[$_.roleDefinitionId]
                Principal = if ($_.principal.PSObject.Properties.Name -contains 'userPrincipalName') { $_.principal.userPrincipalName } else { $_.principal.displayName }
                Portee    = $_.directoryScopeId
            }
        } | Sort-Object Role, Principal
    })
Add-Section 'Attributions de rôles Entra ID' 'roles' $privileged

# --- MFA ----------------------------------------------------------------------------------------------------------
$sd = Invoke-LabGraph -Uri 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
$registration = @(Get-Safe -What 'Inscriptions MFA (Entra ID P1 requis)' -Block {
        Invoke-LabGraph -Uri 'v1.0/reports/authenticationMethods/userRegistrationDetails' | ForEach-Object {
            [pscustomobject]@{
                UPN = $_.userPrincipalName; MfaInscrit = $_.isMfaRegistered; MfaCapable = $_.isMfaCapable
                Methodes = ($_.methodsRegistered -join ', '); Admin = $_.isAdmin
            }
        } | Sort-Object UPN
    })
Add-Section 'Inscription MFA des utilisateurs' 'mfa-registration' $registration `
    "Paramètres de sécurité par défaut : $(if ($sd.isEnabled) { 'activés' } else { 'désactivés (remplacés par l''accès conditionnel)' })"

# --- Accès conditionnel ------------------------------------------------------------------------------------------------
$ca = @(Invoke-LabGraph -Uri 'v1.0/identity/conditionalAccess/policies')
$ca | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path -Path $outDir -ChildPath 'conditional-access-policies.json') -Encoding UTF8
$userNames = @{}
foreach ($u in $users) { $userNames[$u.id] = $u.userPrincipalName }
Add-Section 'Stratégies d''accès conditionnel' 'conditional-access' @($ca | Sort-Object displayName | ForEach-Object {
        [pscustomobject]@{
            Strategie   = $_.displayName
            Etat        = $_.state
            Inclus      = ($_.conditions.users.includeUsers -join ', ')
            Exclus      = (@($_.conditions.users.excludeUsers | ForEach-Object { if ($userNames.ContainsKey($_)) { $userNames[$_] } else { $_ } }) -join ', ')
            Applications = (@($_.conditions.applications.includeApplications) + @($_.conditions.applications.includeUserActions) | Where-Object { $_ }) -join ', '
            Clients     = ($_.conditions.clientAppTypes -join ', ')
            Controles   = ($_.grantControls.builtInControls -join ', ')
        }
    }) 'Définitions complètes dans conditional-access-policies.json.'

Write-LabLog 'Collecte Intune...'

# --- Intune -----------------------------------------------------------------------------------------------------------
$devices = @(Get-Safe -What 'Appareils gérés' -Block {
        Invoke-LabGraph -Uri 'v1.0/deviceManagement/managedDevices?$select=deviceName,operatingSystem,osVersion,complianceState,managementAgent,enrolledDateTime,lastSyncDateTime,userPrincipalName,azureADDeviceId,isEncrypted'
    })
Add-Section 'Appareils gérés par Intune' 'intune-devices' @($devices | ForEach-Object {
        [pscustomobject]@{
            Appareil = $_.deviceName; OS = "$($_.operatingSystem) $($_.osVersion)"; Conformite = $_.complianceState
            Chiffre = $_.isEncrypted; Utilisateur = $_.userPrincipalName; Agent = $_.managementAgent
            Inscrit = $_.enrolledDateTime; DerniereSynchro = $_.lastSyncDateTime
        }
    })

$compliance = @(Get-Safe -What 'Stratégies de conformité' -Block { Invoke-LabGraph -Uri 'v1.0/deviceManagement/deviceCompliancePolicies' })
Add-Section 'Stratégies de conformité' 'intune-compliance' @($compliance | ForEach-Object {
        $ov = Get-Safe -What "Synthèse $($_.displayName)" -Block { Invoke-LabGraph -Uri "v1.0/deviceManagement/deviceCompliancePolicies/$($_.id)/deviceStatusOverview" }
        [pscustomobject]@{
            Strategie = $_.displayName
            Conformes = if ($ov) { $ov.successCount } else { $null }
            NonConformes = if ($ov) { $ov.failedCount } else { $null }
            EnErreur = if ($ov) { $ov.errorCount } else { $null }
            EnAttente = if ($ov) { $ov.pendingCount } else { $null }
        }
    })

$profilesList = @(Get-Safe -What 'Profils de configuration' -Block { Invoke-LabGraph -Uri 'v1.0/deviceManagement/deviceConfigurations' })
Add-Section 'Profils de configuration' 'intune-profiles' @($profilesList | ForEach-Object {
        $ov = Get-Safe -What "Synthèse $($_.displayName)" -Block { Invoke-LabGraph -Uri "v1.0/deviceManagement/deviceConfigurations/$($_.id)/deviceStatusOverview" }
        [pscustomobject]@{
            Profil = $_.displayName; Type = $_.'@odata.type' -replace '#microsoft.graph.', ''
            Reussis = if ($ov) { $ov.successCount } else { $null }; EnErreur = if ($ov) { $ov.errorCount } else { $null }
            EnAttente = if ($ov) { $ov.pendingCount } else { $null }
        }
    })

# --- Exchange (facultatif) ---------------------------------------------------------------------------------------------
if ($IncludeExchange) {
    Import-Module ExchangeOnlineManagement
    if (-not (Get-ConnectionInformation | Where-Object State -EQ 'Connected')) { Connect-ExchangeOnline -ShowBanner:$false }
    $mailboxes = Get-EXOMailbox -ResultSize Unlimited -Properties RecipientTypeDetails |
        Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails
    Add-Section 'Boîtes aux lettres' 'exo-mailboxes' @($mailboxes)
    $shared = foreach ($sm in $mailboxes | Where-Object RecipientTypeDetails -EQ 'SharedMailbox') {
        Get-EXOMailboxPermission -Identity $sm.PrimarySmtpAddress | Where-Object { $_.User -like '*@*' } |
            Select-Object @{ n = 'BoitePartagee'; e = { $sm.PrimarySmtpAddress } }, User, @{ n = 'Droits'; e = { $_.AccessRights -join ',' } }
    }
    Add-Section 'Délégations des boîtes partagées' 'exo-shared-permissions' @($shared)
    $transport = Get-TransportConfig
    $outbound = Get-HostedOutboundSpamFilterPolicy -Identity Default
    Add-Section 'Durcissement Exchange' 'exo-hardening' @([pscustomobject]@{
            SmtpAuthDesactive        = $transport.SmtpClientAuthenticationDisabled
            TransfertAutoExterne     = $outbound.AutoForwardingMode
            AuditBoitesDesactive     = (Get-OrganizationConfig).AuditDisabled
            PopImapActifs            = @(Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum, Imap, Pop | Where-Object { $_.PopEnabled -or $_.ImapEnabled }).Count
        })
}

$index = Export-LabHtmlReport -Directory $outDir -Title "Rapport Microsoft 365 — $($m365.TenantDomain)" -Sections $sections
Write-LabLog "Rapport généré : $index" -Level OK
