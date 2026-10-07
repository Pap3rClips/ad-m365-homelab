#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Crée l'arborescence d'OU, les groupes (modèle AGDLP) et la politique de mots de passe.

.DESCRIPTION
    - OU protégées contre la suppression accidentelle, sous une OU racine dédiée
    - Redirection des conteneurs par défaut Computers / Users vers les OU du lab
      (redircmp / redirusr) : les nouvelles machines n'atterrissent plus dans CN=Computers
    - Groupes globaux (rôles métier) et domaine local (droits sur ressources)
    - Imbrication GG -> DL
    - Politique de mots de passe du domaine + stratégie affinée (FGPP) pour les admins

.EXAMPLE
    .\05-Create-OUStructure.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$fqdn   = $config.Domain.FQDN
$rootOU = $config.Domain.RootOU
$domainDN = Get-LabDomainDN -Fqdn $fqdn

function Get-OUPath([string]$Relative) {
    ConvertTo-LabOUPath -RelativePath $Relative -RootOU $rootOU -Fqdn $fqdn
}

# --- OU racine ------------------------------------------------------------------------
$rootDN = Get-OUPath ''
if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$rootDN'" -ErrorAction SilentlyContinue) {
    Write-LabLog "OU racine $rootOU déjà présente" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($rootDN, 'New-ADOrganizationalUnit')) {
    New-ADOrganizationalUnit -Name $rootOU -Path $domainDN -ProtectedFromAccidentalDeletion $true `
        -Description 'Racine des objets du homelab'
    Write-LabLog "OU racine créée : $rootDN" -Level OK
}

# --- Sous-OU (l'ordre du fichier garantit que le parent existe) -------------------------
foreach ($relative in $config.OrganizationalUnits) {
    $dn = Get-OUPath $relative
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-LabLog "OU $relative déjà présente" -Level SKIP
        continue
    }
    $name   = ($relative -split '/')[-1]
    $parent = $dn.Substring($dn.IndexOf(',') + 1)
    if ($PSCmdlet.ShouldProcess($dn, 'New-ADOrganizationalUnit')) {
        New-ADOrganizationalUnit -Name $name -Path $parent -ProtectedFromAccidentalDeletion $true
        Write-LabLog "OU créée : $relative" -Level OK
    }
}

# --- Redirection des conteneurs par défaut -------------------------------------------------
$domainObj = Get-ADDomain
$targetComputers = Get-OUPath 'Ordinateurs/Postes'
$targetUsers     = Get-OUPath 'Utilisateurs'
if ($domainObj.ComputersContainer -ne $targetComputers -and $PSCmdlet.ShouldProcess($targetComputers, 'redircmp')) {
    & redircmp.exe $targetComputers | Out-Null
    Write-LabLog "Nouveaux ordinateurs -> $targetComputers" -Level OK
}
if ($domainObj.UsersContainer -ne $targetUsers -and $PSCmdlet.ShouldProcess($targetUsers, 'redirusr')) {
    & redirusr.exe $targetUsers | Out-Null
    Write-LabLog "Nouveaux utilisateurs -> $targetUsers" -Level OK
}

# --- Groupes ---------------------------------------------------------------------------------
foreach ($group in $config.Groups) {
    if (Get-ADGroup -Filter "Name -eq '$($group.Name)'" -ErrorAction SilentlyContinue) {
        Write-LabLog "Groupe $($group.Name) déjà présent" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($group.Name, "New-ADGroup ($($group.Scope))")) {
        New-ADGroup -Name $group.Name -SamAccountName $group.Name -GroupScope $group.Scope `
            -GroupCategory Security -Path (Get-OUPath $group.OU) -Description $group.Description
        Write-LabLog "Groupe créé : $($group.Name) [$($group.Scope)]" -Level OK
    }
}

# --- Imbrication AGDLP --------------------------------------------------------------------------
foreach ($nest in $config.GroupNesting) {
    $members = @(Get-ADGroupMember -Identity $nest.Group -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($nest.Member -in $members) {
        Write-LabLog "$($nest.Member) déjà membre de $($nest.Group)" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($nest.Group, "Ajouter $($nest.Member)")) {
        Add-ADGroupMember -Identity $nest.Group -Members $nest.Member
        Write-LabLog "$($nest.Member) -> $($nest.Group)" -Level OK
    }
}

# --- Politique de mots de passe du domaine ---------------------------------------------------------
$pp = $config.PasswordPolicy
if ($PSCmdlet.ShouldProcess($fqdn, 'Set-ADDefaultDomainPasswordPolicy')) {
    Set-ADDefaultDomainPasswordPolicy -Identity $fqdn `
        -MinPasswordLength $pp.MinPasswordLength `
        -PasswordHistoryCount $pp.PasswordHistoryCount `
        -MaxPasswordAge ([timespan]$pp.MaxPasswordAge) `
        -MinPasswordAge ([timespan]$pp.MinPasswordAge) `
        -ComplexityEnabled $true `
        -ReversibleEncryptionEnabled $false `
        -LockoutThreshold $pp.LockoutThreshold `
        -LockoutDuration ([timespan]$pp.LockoutDuration) `
        -LockoutObservationWindow ([timespan]$pp.LockoutObservationWindow)
    Write-LabLog "Politique domaine : $($pp.MinPasswordLength) caractères min., verrouillage après $($pp.LockoutThreshold) échecs" -Level OK
}

# --- Stratégie affinée pour les comptes à privilèges (FGPP) -----------------------------------------
$fgpp = $pp.AdminFGPP
if (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($fgpp.Name)'" -ErrorAction SilentlyContinue) {
    Write-LabLog "FGPP $($fgpp.Name) déjà présente" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($fgpp.Name, 'New-ADFineGrainedPasswordPolicy')) {
    New-ADFineGrainedPasswordPolicy -Name $fgpp.Name -Precedence $fgpp.Precedence `
        -MinPasswordLength $fgpp.MinPasswordLength -MaxPasswordAge ([timespan]$fgpp.MaxPasswordAge) `
        -MinPasswordAge ([timespan]$pp.MinPasswordAge) -PasswordHistoryCount $pp.PasswordHistoryCount `
        -ComplexityEnabled $true -ReversibleEncryptionEnabled $false `
        -LockoutThreshold 3 -LockoutDuration '00:30:00' -LockoutObservationWindow '00:30:00' `
        -ProtectedFromAccidentalDeletion $true
    Add-ADFineGrainedPasswordPolicySubject -Identity $fgpp.Name -Subjects $fgpp.AppliesTo
    # Les admins du domaine sont aussi soumis à la FGPP (SID -512, indépendant de la langue)
    Add-ADFineGrainedPasswordPolicySubject -Identity $fgpp.Name -Subjects "$($domainObj.DomainSID)-512"
    Write-LabLog "FGPP $($fgpp.Name) : $($fgpp.MinPasswordLength) caractères min. pour $($fgpp.AppliesTo) et les admins du domaine" -Level OK
}

# --- Délégation : GG-Admins-Postes gère les comptes ordinateur de l'OU Ordinateurs -------------------
# Permet aux comptes adm-* non admins du domaine de joindre des machines (moindre privilège)
$computersOU = Get-OUPath 'Ordinateurs'
$delegate = "$($config.Domain.NetBIOS)\GG-Admins-Postes"
$acl = (Get-Acl -Path "AD:\$computersOU").Access | Where-Object { $_.IdentityReference -eq $delegate }
if ($acl) {
    Write-LabLog "Délégation déjà en place sur $computersOU" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($computersOU, "Déléguer la gestion des ordinateurs à $delegate")) {
    & dsacls.exe $computersOU /I:T /G "${delegate}:CCDC;computer" | Out-Null
    & dsacls.exe $computersOU /I:S /G "${delegate}:GA;;computer" | Out-Null
    Write-LabLog "Délégation : $delegate peut créer/gérer les ordinateurs sous Ordinateurs" -Level OK
}

# --- Durcissement : les utilisateurs standard ne peuvent plus joindre de machines --------------------
$maq = (Get-ADObject -Identity $domainDN -Properties 'ms-DS-MachineAccountQuota').'ms-DS-MachineAccountQuota'
if ($maq -eq 0) {
    Write-LabLog 'ms-DS-MachineAccountQuota déjà à 0' -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($domainDN, 'ms-DS-MachineAccountQuota = 0')) {
    Set-ADDomain -Identity $fqdn -Replace @{ 'ms-DS-MachineAccountQuota' = 0 }
    Write-LabLog "ms-DS-MachineAccountQuota : $maq -> 0 (seuls les comptes délégués joignent des machines)" -Level OK
}

Write-LabLog 'Structure prête. Étape suivante : 06-Import-Users.ps1' -Level OK
