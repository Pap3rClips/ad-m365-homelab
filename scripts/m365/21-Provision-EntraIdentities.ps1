#Requires -Version 5.1

<#
.SYNOPSIS
    Provisionne les identités Entra ID : utilisateurs cloud, groupe de licences,
    groupes dynamiques et groupes Microsoft 365 (qui créent les sites d'équipe SharePoint).

.DESCRIPTION
    - Utilisateurs de data/users.csv dont la colonne M365 vaut true, UPN <identifiant>@<tenant>
      (même identifiant que dans AD, mots de passe aléatoires dans output/secrets/)
    - Licences attribuées par groupe (SG-M365-Licences) : un utilisateur ajouté au groupe est
      licencié automatiquement, retiré il perd sa licence. Nécessite Entra ID P1 (inclus E5 / Business Premium).
    - Groupes dynamiques par service (règle sur l'attribut department) et pour les appareils Windows
    - Groupes Microsoft 365 privés par service : boîte partagée de groupe + site SharePoint d'équipe

    Les comptes sont « cloud only » : le lab AD et le tenant ne sont pas synchronisés.
    La synchronisation (Entra Connect Sync / Cloud Sync) est décrite comme évolution dans docs/.

.EXAMPLE
    .\21-Provision-EntraIdentities.ps1 -WhatIf
    .\21-Provision-EntraIdentities.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$UsersCsv
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabM365/LabM365.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
if (-not $UsersCsv) { $UsersCsv = Join-Path -Path (Get-LabRoot) -ChildPath 'data/users.csv' }
$m365 = $config.M365
$tenant = $m365.TenantDomain

Connect-LabGraph -TenantDomain $tenant -Scopes @(
    'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.ReadWrite.All', 'Organization.Read.All'
) | Out-Null

$secretFile = 'm365-initial-passwords-{0:yyyyMMdd-HHmm}.csv' -f (Get-Date)

# =====================================================================================
# 1. Utilisateurs
# =====================================================================================
$rows = Import-LabCsv -Path $UsersCsv -RequiredColumns 'GivenName', 'Surname', 'Department', 'Title', 'Office', 'M365' |
    Where-Object { $_.M365 -eq 'true' }
$cloudUsers = [Collections.Generic.List[object]]::new()

foreach ($u in $rows) {
    $sam = ConvertTo-LabSamAccountName -GivenName $u.GivenName -Surname $u.Surname
    $upn = "$sam@$tenant"
    $existing = Get-LabGraphUser -UserPrincipalName $upn
    if ($existing) {
        Write-LabLog "Utilisateur $upn déjà présent" -Level SKIP
        $cloudUsers.Add([pscustomobject]@{ Id = $existing.id; Upn = $upn; Department = $u.Department })
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($upn, 'Créer l''utilisateur Entra ID')) { continue }

    $password = New-LabPassword -Length 16
    $body = @{
        accountEnabled    = $true
        displayName       = "$($u.GivenName) $($u.Surname)"
        givenName         = $u.GivenName
        surname           = $u.Surname
        mailNickname      = $sam
        userPrincipalName = $upn
        usageLocation     = $m365.UsageLocation      # obligatoire pour attribuer une licence
        department        = $u.Department
        jobTitle          = $u.Title
        officeLocation    = $u.Office
        companyName       = 'Hadrien Lab'
        passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $true }
    }
    $created = Invoke-LabGraph -Method POST -Uri 'v1.0/users' -Body $body
    Export-LabSecret -FileName $secretFile -Entry ([pscustomobject]@{ Compte = $upn; MotDePasseInitial = $password })
    $cloudUsers.Add([pscustomobject]@{ Id = $created.id; Upn = $upn; Department = $u.Department })
    Write-LabLog "Utilisateur créé : $upn ($($u.Department))" -Level OK
}

# =====================================================================================
# 2. Groupe de licences + attribution de licence au groupe
# =====================================================================================
$licGroupName = $m365.LicensedGroup
$licGroup = Get-LabGraphGroup -DisplayName $licGroupName
if (-not $licGroup -and $PSCmdlet.ShouldProcess($licGroupName, 'Créer le groupe de sécurité')) {
    $licGroup = Invoke-LabGraph -Method POST -Uri 'v1.0/groups' -Body @{
        displayName     = $licGroupName
        description     = 'Membres licenciés Microsoft 365 (licence attribuée au groupe)'
        mailEnabled     = $false
        mailNickname    = $licGroupName.ToLowerInvariant()
        securityEnabled = $true
        groupTypes      = @()
    }
    Write-LabLog "Groupe $licGroupName créé" -Level OK
}

if ($licGroup) {
    $added = 0
    foreach ($cu in $cloudUsers) {
        if (Add-LabGraphGroupMember -GroupId $licGroup.id -MemberId $cu.Id) { $added++ }
    }
    Write-LabLog "$added utilisateur(s) ajouté(s) à $licGroupName" -Level $(if ($added) { 'OK' } else { 'SKIP' })

    $skus = @(Invoke-LabGraph -Uri 'v1.0/subscribedSkus?$select=skuId,skuPartNumber,prepaidUnits,consumedUnits')
    $sku = $skus | Where-Object skuPartNumber -EQ $m365.LicenseSkuPartNumber
    if (-not $sku) {
        Write-LabLog "SKU $($m365.LicenseSkuPartNumber) absent du tenant. Disponibles : $(($skus.skuPartNumber) -join ', '). Corrige M365.LicenseSkuPartNumber." -Level WARN
    }
    else {
        $groupLicenses = @((Invoke-LabGraph -Uri "v1.0/groups/$($licGroup.id)?`$select=assignedLicenses").assignedLicenses | ForEach-Object { $_.skuId })
        if ($sku.skuId -in $groupLicenses) {
            Write-LabLog "Licence $($sku.skuPartNumber) déjà attribuée à $licGroupName" -Level SKIP
        }
        elseif ($PSCmdlet.ShouldProcess($licGroupName, "Attribuer $($sku.skuPartNumber)")) {
            try {
                Invoke-LabGraph -Method POST -Uri "v1.0/groups/$($licGroup.id)/assignLicense" -Body @{
                    addLicenses    = @(@{ skuId = $sku.skuId; disabledPlans = @() })
                    removeLicenses = @()
                } | Out-Null
                Write-LabLog "Licence $($sku.skuPartNumber) attribuée à $licGroupName ($($sku.prepaidUnits.enabled - $sku.consumedUnits) disponibles avant attribution)" -Level OK
            }
            catch {
                Write-LabLog "Licence de groupe refusée : $(Get-LabGraphErrorMessage $_). Les licences par groupe exigent Entra ID P1." -Level WARN
            }
        }
    }
}

# =====================================================================================
# 3. Groupes dynamiques
# =====================================================================================
foreach ($dg in $m365.DynamicGroups) {
    if (Get-LabGraphGroup -DisplayName $dg.Name) {
        Write-LabLog "Groupe dynamique $($dg.Name) déjà présent" -Level SKIP
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($dg.Name, "Créer le groupe dynamique : $($dg.Rule)")) { continue }
    $isDevice = $dg.ContainsKey('Devices') -and $dg.Devices
    Invoke-LabGraph -Method POST -Uri 'v1.0/groups' -Body @{
        displayName                   = $dg.Name
        description                   = if ($isDevice) { 'Appareils Windows (dynamique) - cible Intune' } else { "Utilisateurs (dynamique) : $($dg.Rule)" }
        mailEnabled                   = $false
        mailNickname                  = $dg.Name.ToLowerInvariant()
        securityEnabled               = $true
        groupTypes                    = @('DynamicMembership')
        membershipRule                = $dg.Rule
        membershipRuleProcessingState = 'On'
    } | Out-Null
    Write-LabLog "Groupe dynamique créé : $($dg.Name) [$($dg.Rule)]" -Level OK
}

# =====================================================================================
# 4. Groupes Microsoft 365 (sites d'équipe SharePoint)
# =====================================================================================
$me = Invoke-LabGraph -Uri 'v1.0/me?$select=id,userPrincipalName'
foreach ($ts in $m365.TeamSites) {
    $group = Get-LabGraphGroup -DisplayName $ts.Name
    if (-not $group) {
        if (-not $PSCmdlet.ShouldProcess($ts.Name, 'Créer le groupe Microsoft 365')) { continue }
        $group = Invoke-LabGraph -Method POST -Uri 'v1.0/groups' -Body @{
            displayName        = $ts.Name
            description        = "Espace collaboratif du service $($ts.Department)"
            mailEnabled        = $true
            mailNickname       = $ts.Alias
            securityEnabled    = $false
            groupTypes         = @('Unified')
            visibility         = 'Private'
            'owners@odata.bind' = @("https://graph.microsoft.com/v1.0/users/$($me.id)")
        }
        Write-LabLog "Groupe Microsoft 365 créé : $($ts.Name) (site SharePoint provisionné sous quelques minutes)" -Level OK
    }
    else {
        Write-LabLog "Groupe Microsoft 365 $($ts.Name) déjà présent" -Level SKIP
    }
    foreach ($cu in $cloudUsers | Where-Object Department -EQ $ts.Department) {
        if (Add-LabGraphGroupMember -GroupId $group.id -MemberId $cu.Id) {
            Write-LabLog "$($cu.Upn) -> $($ts.Name)" -Level OK
        }
    }
}

if (Test-Path -Path (Join-Path -Path (Get-LabRoot) -ChildPath "output/secrets/$secretFile")) {
    Write-LabLog "Mots de passe initiaux : output/secrets/$secretFile — à supprimer après transmission" -Level WARN
}
Write-LabLog 'Les boîtes aux lettres apparaissent ~5 à 15 min après la licence. Étape suivante : 22-Configure-Exchange.ps1' -Level OK
