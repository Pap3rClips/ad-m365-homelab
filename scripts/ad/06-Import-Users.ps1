#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Crée les comptes utilisateurs (data/users.csv) et les comptes d'administration
    séparés (data/admins.csv), puis les place dans leurs groupes.

.DESCRIPTION
    - Identifiant : initiale + nom, sans accents (ConvertTo-LabSamAccountName)
    - Chaque compte reçoit un mot de passe aléatoire unique, à changer à la 1re connexion
    - Les mots de passe initiaux sont écrits dans output/secrets/ (exclu de Git) :
      transmets-les puis supprime le fichier
    - Les comptes adm-* sont « sensibles et ne peuvent pas être délégués »
      et ajoutés au groupe Protected Users lorsqu'ils sont admins du domaine

.EXAMPLE
    .\06-Import-Users.ps1 -WhatIf
    .\06-Import-Users.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$UsersCsv,
    [string]$AdminsCsv
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$root = Get-LabRoot
if (-not $UsersCsv)  { $UsersCsv  = Join-Path -Path $root -ChildPath 'data/users.csv' }
if (-not $AdminsCsv) { $AdminsCsv = Join-Path -Path $root -ChildPath 'data/admins.csv' }

$fqdn   = $config.Domain.FQDN
$rootOU = $config.Domain.RootOU
$domain = Get-ADDomain
$secretFile = 'ad-initial-passwords-{0:yyyyMMdd-HHmm}.csv' -f (Get-Date)

# Résout un nom de groupe ; @DomainAdmins / @ProtectedUsers = SID bien connus (indépendants de la langue de l'OS)
function Resolve-LabGroup([string]$Name) {
    switch ($Name) {
        '@DomainAdmins'   { return Get-ADGroup -Identity "$($domain.DomainSID)-512" }
        '@ProtectedUsers' { return Get-ADGroup -Identity "$($domain.DomainSID)-525" }
        default           { return Get-ADGroup -Identity $Name }
    }
}

# --- Utilisateurs métier ----------------------------------------------------------------------
$users = Import-LabCsv -Path $UsersCsv -RequiredColumns 'GivenName', 'Surname', 'Department', 'Title', 'Office', 'Groups'
$created = 0

foreach ($u in $users) {
    $sam = ConvertTo-LabSamAccountName -GivenName $u.GivenName -Surname $u.Surname
    $upn = "$sam@$fqdn"
    $ouPath = ConvertTo-LabOUPath -RelativePath "Utilisateurs/$($u.Department)" -RootOU $rootOU -Fqdn $fqdn

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-LabLog "Utilisateur $sam déjà présent" -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess($upn, "New-ADUser dans $ouPath")) {
        $password = New-LabPassword -Length 16
        $params = @{
            Name                  = "$($u.GivenName) $($u.Surname)"
            GivenName             = $u.GivenName
            Surname               = $u.Surname
            DisplayName           = "$($u.GivenName) $($u.Surname)"
            SamAccountName        = $sam
            UserPrincipalName     = $upn
            EmailAddress          = $upn
            Department            = $u.Department
            Title                 = $u.Title
            Office                = $u.Office
            Company               = 'Hadrien Lab'
            Path                  = $ouPath
            AccountPassword       = (ConvertTo-SecureString -String $password -AsPlainText -Force)
            ChangePasswordAtLogon = $true
            Enabled               = $true
        }
        New-ADUser @params
        Export-LabSecret -FileName $secretFile -Entry ([pscustomobject]@{ Compte = $sam; MotDePasseInitial = $password })
        $created++
        Write-LabLog "Utilisateur créé : $sam ($($u.Department))" -Level OK
    }

    foreach ($g in ($u.Groups -split ';' | Where-Object { $_ })) {
        $group = Resolve-LabGroup $g
        $isMember = Get-ADGroupMember -Identity $group | Where-Object SamAccountName -EQ $sam
        if (-not $isMember -and $PSCmdlet.ShouldProcess($group.Name, "Ajouter $sam")) {
            Add-ADGroupMember -Identity $group -Members $sam
            Write-LabLog "$sam -> $($group.Name)" -Level OK
        }
    }
}

# --- Comptes d'administration séparés -------------------------------------------------------------
$admins = Import-LabCsv -Path $AdminsCsv -RequiredColumns 'SamAccountName', 'DisplayName', 'Owner', 'Groups'
$adminOU = ConvertTo-LabOUPath -RelativePath 'Comptes-Admin' -RootOU $rootOU -Fqdn $fqdn

foreach ($a in $admins) {
    if (Get-ADUser -Filter "SamAccountName -eq '$($a.SamAccountName)'" -ErrorAction SilentlyContinue) {
        Write-LabLog "Compte admin $($a.SamAccountName) déjà présent" -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess($a.SamAccountName, 'Créer le compte admin')) {
        $password = New-LabPassword -Length 20
        New-ADUser -Name $a.DisplayName -DisplayName $a.DisplayName -SamAccountName $a.SamAccountName `
            -UserPrincipalName "$($a.SamAccountName)@$fqdn" -Path $adminOU `
            -Description "Compte d'administration de $($a.Owner) — ne pas utiliser pour la bureautique" `
            -AccountPassword (ConvertTo-SecureString -String $password -AsPlainText -Force) `
            -AccountNotDelegated $true -ChangePasswordAtLogon $true -Enabled $true
        Export-LabSecret -FileName $secretFile -Entry ([pscustomobject]@{ Compte = $a.SamAccountName; MotDePasseInitial = $password })
        $created++
        Write-LabLog "Compte admin créé : $($a.SamAccountName) (non délégable)" -Level OK
    }

    $groups = @($a.Groups -split ';' | Where-Object { $_ })
    foreach ($g in $groups) {
        $group = Resolve-LabGroup $g
        $isMember = Get-ADGroupMember -Identity $group | Where-Object SamAccountName -EQ $a.SamAccountName
        if (-not $isMember -and $PSCmdlet.ShouldProcess($group.Name, "Ajouter $($a.SamAccountName)")) {
            Add-ADGroupMember -Identity $group -Members $a.SamAccountName
            Write-LabLog "$($a.SamAccountName) -> $($group.Name)" -Level OK
        }
    }

    # Admins du domaine -> Protected Users (pas de NTLM, pas de délégation, TGT 4 h)
    if ('@DomainAdmins' -in $groups) {
        $pu = Resolve-LabGroup '@ProtectedUsers'
        if (-not (Get-ADGroupMember -Identity $pu | Where-Object SamAccountName -EQ $a.SamAccountName) -and
            $PSCmdlet.ShouldProcess($pu.Name, "Ajouter $($a.SamAccountName)")) {
            Add-ADGroupMember -Identity $pu -Members $a.SamAccountName
            Write-LabLog "$($a.SamAccountName) -> $($pu.Name)" -Level OK
        }
    }
}

if ($created -gt 0) {
    Write-LabLog "$created compte(s) créé(s). Mots de passe initiaux : output/secrets/$secretFile — à supprimer après transmission" -Level WARN
}
Write-LabLog 'Utilisateurs prêts. Étape suivante : 07-Join-Domain.ps1 sur chaque machine membre' -Level OK
