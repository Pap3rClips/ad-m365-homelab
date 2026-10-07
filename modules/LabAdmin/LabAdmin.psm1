#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Fonctions d'administration courante de l'annuaire : arrivées, départs, réinitialisations,
    audit des comptes à risque et santé du contrôleur de domaine.

.EXAMPLE
    Import-Module .\modules\LabAdmin\LabAdmin.psm1
    New-LabUser -GivenName 'Emma' -Surname 'Petit' -Department 'Commercial' -Title 'Commerciale'
    Disable-LabUser -Identity epetit -Reason 'Départ le 31/10'
    Get-LabAccountRisk | Format-Table
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../LabCommon/LabCommon.psm1')

function Get-LabContext {
    $config = Import-LabConfig
    [pscustomobject]@{
        Config = $config
        Fqdn   = $config.Domain.FQDN
        RootOU = $config.Domain.RootOU
        Domain = Get-ADDomain
    }
}

function New-LabUser {
    <#
    .SYNOPSIS
        Arrivée d'un collaborateur : compte, OU du service, groupe du service, mot de passe initial.
    .OUTPUTS
        Objet contenant l'identifiant et le mot de passe initial (à transmettre puis oublier).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [Parameter(Mandatory)][ValidateSet('Direction', 'IT', 'Comptabilite', 'Commercial')][string]$Department,
        [Parameter(Mandatory)][string]$Title,
        [string]$Office = 'Pontoise',
        [string[]]$AdditionalGroups = @()
    )
    $ctx = Get-LabContext
    $sam = ConvertTo-LabSamAccountName -GivenName $GivenName -Surname $Surname
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
        throw "L'identifiant $sam existe déjà. Choisis un identifiant manuellement (homonyme)."
    }
    $password = New-LabPassword -Length 16
    $ou = ConvertTo-LabOUPath -RelativePath "Utilisateurs/$Department" -RootOU $ctx.RootOU -Fqdn $ctx.Fqdn

    if ($PSCmdlet.ShouldProcess("$sam@$($ctx.Fqdn)", 'Créer le compte')) {
        New-ADUser -Name "$GivenName $Surname" -GivenName $GivenName -Surname $Surname -DisplayName "$GivenName $Surname" `
            -SamAccountName $sam -UserPrincipalName "$sam@$($ctx.Fqdn)" -EmailAddress "$sam@$($ctx.Fqdn)" `
            -Department $Department -Title $Title -Office $Office -Company 'Hadrien Lab' -Path $ou `
            -AccountPassword (ConvertTo-SecureString -String $password -AsPlainText -Force) `
            -ChangePasswordAtLogon $true -Enabled $true
        foreach ($g in @("GG-$Department") + $AdditionalGroups) {
            Add-ADGroupMember -Identity $g -Members $sam
        }
        Write-LabLog "Arrivée : $sam ($Department, $Title)" -Level OK
    }
    [pscustomobject]@{ SamAccountName = $sam; InitialPassword = $password; OU = $ou }
}

function Disable-LabUser {
    <#
    .SYNOPSIS
        Départ d'un collaborateur : désactivation, mot de passe aléatoire, retrait des groupes,
        déplacement vers l'OU Desactives et traçabilité dans la description.
        Le compte est conservé (récupération de données, audit) ; suppression manuelle après 90 j.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('SamAccountName')][string]$Identity,
        [Parameter(Mandatory)][string]$Reason
    )
    begin { $ctx = Get-LabContext }
    process {
        $user = Get-ADUser -Identity $Identity -Properties MemberOf, Description
        $target = ConvertTo-LabOUPath -RelativePath 'Desactives' -RootOU $ctx.RootOU -Fqdn $ctx.Fqdn
        if (-not $PSCmdlet.ShouldProcess($user.SamAccountName, 'Désactiver (départ)')) { return }

        Disable-ADAccount -Identity $user
        Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString -String (New-LabPassword -Length 32) -AsPlainText -Force)
        $groups = @($user.MemberOf)
        foreach ($g in $groups) {
            Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd'
        Set-ADUser -Identity $user -Description "Désactivé le $stamp par $env:USERNAME : $Reason" `
            -Replace @{ info = "Groupes retirés : $(($groups | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join '; ')" }
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $target
        Write-LabLog "Départ : $($user.SamAccountName) désactivé, $($groups.Count) groupe(s) retiré(s), déplacé vers Desactives" -Level OK
    }
}

function Reset-LabUserPassword {
    <# .SYNOPSIS Réinitialise le mot de passe, déverrouille le compte et force le changement à la connexion. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('SamAccountName')][string]$Identity)
    process {
        $password = New-LabPassword -Length 16
        if ($PSCmdlet.ShouldProcess($Identity, 'Réinitialiser le mot de passe')) {
            Set-ADAccountPassword -Identity $Identity -Reset -NewPassword (ConvertTo-SecureString -String $password -AsPlainText -Force)
            Unlock-ADAccount -Identity $Identity
            Set-ADUser -Identity $Identity -ChangePasswordAtLogon $true
            Write-LabLog "Mot de passe réinitialisé et compte déverrouillé : $Identity" -Level OK
        }
        [pscustomobject]@{ SamAccountName = $Identity; TemporaryPassword = $password }
    }
}

function Get-LabLockedAccount {
    <# .SYNOPSIS Comptes actuellement verrouillés, avec la dernière tentative en échec. #>
    [CmdletBinding()]
    param()
    Search-ADAccount -LockedOut -UsersOnly |
        Get-ADUser -Properties LockoutTime, BadLogonCount, LastBadPasswordAttempt |
        Select-Object SamAccountName, BadLogonCount, LastBadPasswordAttempt,
            @{ n = 'LockedSince'; e = { [datetime]::FromFileTime($_.LockoutTime) } }
}

function Get-LabStaleAccount {
    <#
    .SYNOPSIS Comptes actifs sans connexion depuis N jours (lastLogonTimestamp, précision ~14 j).
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(14, 3650)][int]$Days = 90,
        [ValidateSet('User', 'Computer')][string]$Type = 'User'
    )
    $limit = (Get-Date).AddDays(-$Days)
    $filter = { Enabled -eq $true -and (LastLogonTimestamp -lt $limit -or LastLogonTimestamp -notlike '*') }
    $props = 'LastLogonDate', 'whenCreated', 'Description'
    $objects = if ($Type -eq 'User') { Get-ADUser -Filter $filter -Properties $props } else { Get-ADComputer -Filter $filter -Properties $props }
    $objects | Where-Object { $_.whenCreated -lt $limit } |
        Select-Object SamAccountName, LastLogonDate, whenCreated, DistinguishedName
}

function Get-LabPrivilegedMember {
    <#
    .SYNOPSIS Membres (récursifs) des groupes à privilèges, identifiés par SID bien connu.
    #>
    [CmdletBinding()]
    param()
    $sid = (Get-ADDomain).DomainSID.Value
    $rootSid = (Get-ADDomain -Identity (Get-ADForest).RootDomain).DomainSID.Value
    $groups = [ordered]@{
        "$sid-512"     = 'Admins du domaine'
        "$rootSid-519" = 'Administrateurs de l''entreprise'
        "$rootSid-518" = 'Administrateurs du schéma'
        'S-1-5-32-544' = 'Administrateurs (BUILTIN)'
        'S-1-5-32-548' = 'Opérateurs de compte'
        'S-1-5-32-551' = 'Opérateurs de sauvegarde'
        'S-1-5-32-549' = 'Opérateurs de serveur'
    }
    foreach ($g in $groups.Keys) {
        $group = Get-ADGroup -Identity $g -ErrorAction SilentlyContinue
        if (-not $group) { continue }
        Get-ADGroupMember -Identity $group -Recursive | Where-Object objectClass -EQ 'user' | ForEach-Object {
            $u = Get-ADUser -Identity $_ -Properties Enabled, LastLogonDate, PasswordLastSet
            [pscustomobject]@{
                Group           = $groups[$g]
                SamAccountName  = $u.SamAccountName
                Enabled         = $u.Enabled
                LastLogonDate   = $u.LastLogonDate
                PasswordLastSet = $u.PasswordLastSet
            }
        }
    }
}

function Get-LabAccountRisk {
    <#
    .SYNOPSIS
        Repère les configurations de comptes exploitées en test d'intrusion AD :
        Kerberoasting (SPN sur un compte utilisateur), AS-REP roasting (pré-auth désactivée),
        mot de passe non requis / jamais expiré, chiffrement réversible, délégation non contrainte,
        comptes à privilèges délégables.
    #>
    [CmdletBinding()]
    param()
    $props = 'ServicePrincipalName', 'DoesNotRequirePreAuth', 'PasswordNotRequired', 'PasswordNeverExpires',
        'AllowReversiblePasswordEncryption', 'TrustedForDelegation', 'AccountNotDelegated', 'adminCount'
    foreach ($u in Get-ADUser -Filter 'Enabled -eq $true' -Properties $props) {
        $findings = [Collections.Generic.List[string]]::new()
        if ($u.ServicePrincipalName -and $u.SamAccountName -ne 'krbtgt') { $findings.Add('Kerberoastable (SPN)') }
        if ($u.DoesNotRequirePreAuth)             { $findings.Add('AS-REP roastable') }
        if ($u.PasswordNotRequired)               { $findings.Add('Mot de passe non requis') }
        if ($u.PasswordNeverExpires)              { $findings.Add('Mot de passe sans expiration') }
        if ($u.AllowReversiblePasswordEncryption) { $findings.Add('Chiffrement réversible') }
        if ($u.TrustedForDelegation)              { $findings.Add('Délégation non contrainte') }
        if ($u.adminCount -eq 1 -and -not $u.AccountNotDelegated) { $findings.Add('Compte privilégié délégable') }
        if ($findings.Count -gt 0) {
            [pscustomobject]@{ SamAccountName = $u.SamAccountName; Findings = $findings -join ' | ' }
        }
    }
    # Machines (hors DC) en délégation non contrainte
    Get-ADComputer -Filter 'TrustedForDelegation -eq $true -and PrimaryGroupID -ne 516' |
        ForEach-Object { [pscustomobject]@{ SamAccountName = $_.SamAccountName; Findings = 'Ordinateur en délégation non contrainte' } }
}

function Get-LabGroupMembership {
    <# .SYNOPSIS Membres directs de chaque groupe du lab (GG-* et DL-*), pour revue des accès. #>
    [CmdletBinding()]
    param()
    Get-ADGroup -Filter "Name -like 'GG-*' -or Name -like 'DL-*'" -Properties Description | Sort-Object Name | ForEach-Object {
        $g = $_
        $members = @(Get-ADGroupMember -Identity $g | Select-Object -ExpandProperty SamAccountName)
        [pscustomobject]@{
            Group       = $g.Name
            Scope       = $g.GroupScope
            Description = $g.Description
            Count       = $members.Count
            Members     = $members -join ', '
        }
    }
}

function Test-LabDomainHealth {
    <#
    .SYNOPSIS Contrôles de santé du DC : services, SRV DNS, SYSVOL, dcdiag, heure, DHCP.
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-LabContext
    $results = [Collections.Generic.List[object]]::new()
    function Add-Result([string]$Check, [bool]$Ok, [string]$Detail) {
        $results.Add([pscustomobject]@{ Check = $Check; Status = if ($Ok) { 'OK' } else { 'KO' }; Detail = $Detail })
    }

    foreach ($svc in 'NTDS', 'DNS', 'Netlogon', 'Kdc', 'W32Time', 'DFSR', 'DHCPServer') {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        Add-Result "Service $svc" ($s -and $s.Status -eq 'Running') $(if ($s) { [string]$s.Status } else { 'absent' })
    }
    foreach ($srv in "_ldap._tcp.dc._msdcs.$($ctx.Fqdn)", "_kerberos._tcp.$($ctx.Fqdn)") {
        $r = Resolve-DnsName -Name $srv -Type SRV -ErrorAction SilentlyContinue
        Add-Result "SRV $srv" ([bool]$r) $(if ($r) { ($r | Where-Object Type -EQ 'SRV').NameTarget -join ', ' } else { 'non résolu' })
    }
    $sysvol = Test-Path -Path "\\$($ctx.Fqdn)\SYSVOL\$($ctx.Fqdn)\Policies"
    Add-Result 'Partage SYSVOL' $sysvol "\\$($ctx.Fqdn)\SYSVOL"

    $dcdiag = & dcdiag.exe /q 2>&1
    Add-Result 'dcdiag /q' ($LASTEXITCODE -eq 0 -and -not $dcdiag) $(if ($dcdiag) { ($dcdiag | Select-Object -First 3) -join ' ' } else { 'aucune erreur' })

    $time = & w32tm.exe /query /source 2>&1
    Add-Result 'Source de temps' ($LASTEXITCODE -eq 0) ([string]($time | Select-Object -First 1))

    if (Get-Command -Name Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue) {
        Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Result "DHCP $($_.ScopeId)" ($_.PercentageInUse -lt 90) ("{0} baux, {1:N0} % utilisés" -f $_.InUse, $_.PercentageInUse)
        }
    }
    $results
}

Export-ModuleMember -Function New-LabUser, Disable-LabUser, Reset-LabUserPassword, Get-LabLockedAccount,
    Get-LabStaleAccount, Get-LabPrivilegedMember, Get-LabAccountRisk, Get-LabGroupMembership, Test-LabDomainHealth
