#Requires -Version 5.1
#Requires -PSEdition Desktop

<#
.SYNOPSIS
    Configure SharePoint Online : site de communication Intranet, partage externe maîtrisé,
    sites d'équipe des groupes Microsoft 365.

.DESCRIPTION
    À lancer dans Windows PowerShell 5.1 (powershell.exe) : le module
    Microsoft.Online.SharePoint.PowerShell y est pleinement supporté.

    - Site de communication « Intranet » (modèle SITEPAGEPUBLISHING#0)
    - Partage au niveau du tenant : invités déjà présents dans l'annuaire uniquement,
      liens par défaut internes et en lecture seule, pas de repartage par les invités
    - OneDrive : même niveau de partage
    - Site d'équipe Comptabilité : partage externe désactivé
    - Les sites d'équipe sont créés automatiquement avec les groupes Microsoft 365 (script 21)

.PARAMETER OwnerUpn
    Compte administrateur propriétaire des sites (ex. admin@hadrienlab.onmicrosoft.com).

.EXAMPLE
    powershell.exe -File .\23-Configure-SharePoint.ps1 -OwnerUpn admin@hadrienlab.onmicrosoft.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$OwnerUpn,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$m365 = $config.M365
$prefix = $m365.SharePointPrefix
$adminUrl = "https://$prefix-admin.sharepoint.com"
$rootUrl  = "https://$prefix.sharepoint.com"

Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking
try { Get-SPOTenant -ErrorAction Stop | Out-Null }
catch { Connect-SPOService -Url $adminUrl }
Write-LabLog "Connecté à $adminUrl" -Level OK

# =====================================================================================
# 1. Partage au niveau du tenant
# =====================================================================================
if ($PSCmdlet.ShouldProcess($adminUrl, 'Restreindre le partage externe')) {
    Set-SPOTenant -SharingCapability ExistingExternalUserSharingOnly `
        -DefaultSharingLinkType Internal `
        -DefaultLinkPermission View `
        -PreventExternalUsersFromResharing $true `
        -RequireAcceptingAccountMatchInvitedAccount $true
    Set-SPOTenant -OneDriveSharingCapability ExistingExternalUserSharingOnly
    Write-LabLog 'Partage : invités existants uniquement, liens internes en lecture par défaut, pas de repartage' -Level OK
}

# =====================================================================================
# 2. Site de communication
# =====================================================================================
foreach ($site in $m365.SharePointSites) {
    $url = "$rootUrl/sites/$($site.Url)"
    $existing = $null
    try { $existing = Get-SPOSite -Identity $url -ErrorAction Stop } catch { $existing = $null }
    if ($existing) {
        Write-LabLog "Site $url déjà présent" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($url, "New-SPOSite ($($site.Template))")) {
        New-SPOSite -Url $url -Title $site.Title -Owner $OwnerUpn -Template $site.Template `
            -StorageQuota 1024 -LocaleId 1036 -TimeZoneId 3
        Set-SPOSite -Identity $url -SharingCapability Disabled
        Write-LabLog "Site de communication créé : $url (français, partage externe désactivé)" -Level OK
    }
}

# =====================================================================================
# 3. Sites d'équipe des groupes Microsoft 365
# =====================================================================================
foreach ($ts in $m365.TeamSites) {
    $url = "$rootUrl/sites/$($ts.Alias)"
    $site = $null
    try { $site = Get-SPOSite -Identity $url -ErrorAction Stop } catch { $site = $null }
    if (-not $site) {
        Write-LabLog "Site d'équipe $url pas encore provisionné (groupe créé il y a peu ?) : relance plus tard" -Level WARN
        continue
    }
    $target = if ($ts.Department -eq 'Comptabilite') { 'Disabled' } else { 'ExistingExternalUserSharingOnly' }
    if ($site.SharingCapability -ne $target -and $PSCmdlet.ShouldProcess($url, "Partage = $target")) {
        Set-SPOSite -Identity $url -SharingCapability $target
        Write-LabLog "Site d'équipe $url : partage $target" -Level OK
    }
    else {
        Write-LabLog "Site d'équipe $url conforme ($target)" -Level SKIP
    }
}

Get-SPOSite -Limit All | Where-Object { $_.Url -like "$rootUrl/sites/*" } |
    Format-Table Url, Template, SharingCapability, Owner -AutoSize
Write-LabLog 'SharePoint configuré. Étape suivante : 24-Configure-MFA-ConditionalAccess.ps1' -Level OK
