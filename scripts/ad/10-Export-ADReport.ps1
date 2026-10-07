#Requires -Version 5.1
#Requires -Modules ActiveDirectory, GroupPolicy

<#
.SYNOPSIS
    Produit un rapport HTML + CSV de l'état du domaine : preuves de réalisation du lab
    et revue de sécurité. À relancer après chaque évolution.

.DESCRIPTION
    Contenu : domaine et forêt, arborescence d'OU, ordinateurs joints, utilisateurs par OU,
    groupes et membres, GPO et liens, politique de mots de passe, membres à privilèges,
    comptes à risque, DNS, DHCP, contrôles de santé.
    Sortie : output/evidence/ad-AAAAMMJJ-HHMM/ (index.html, *.csv, rapports GPO).

.EXAMPLE
    .\10-Export-ADReport.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabAdmin/LabAdmin.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$fqdn = $config.Domain.FQDN
$rootDN = ConvertTo-LabOUPath -RelativePath '' -RootOU $config.Domain.RootOU -Fqdn $fqdn

$outDir = Join-Path -Path (Get-LabRoot) -ChildPath ('output/evidence/ad-{0:yyyyMMdd-HHmm}' -f (Get-Date))
New-Item -Path (Join-Path -Path $outDir -ChildPath 'gpo') -ItemType Directory -Force | Out-Null

$sections = [Collections.Generic.List[object]]::new()
function Add-Section {
    param([string]$Title, [string]$CsvName, [object[]]$Data, [string]$Note = '')
    $sections.Add(@{ Title = $Title; CsvName = $CsvName; Data = $Data; Note = $Note })
}

Write-LabLog 'Collecte des informations du domaine...'
$domain = Get-ADDomain
$forest = Get-ADForest
Add-Section -Title 'Domaine et forêt' -CsvName 'domain' -Data @([pscustomobject]@{
        Domaine           = $domain.DNSRoot
        NetBIOS           = $domain.NetBIOSName
        NiveauDomaine     = $domain.DomainMode
        NiveauForet       = $forest.ForestMode
        PDC               = $domain.PDCEmulator
        ConteneurOrdis    = $domain.ComputersContainer
        ConteneurUsers    = $domain.UsersContainer
        MachineAccountQuota = (Get-ADObject -Identity $domain.DistinguishedName -Properties 'ms-DS-MachineAccountQuota').'ms-DS-MachineAccountQuota'
    })

$ous = Get-ADOrganizationalUnit -SearchBase $rootDN -Filter * -Properties ProtectedFromAccidentalDeletion |
    Sort-Object { ($_.DistinguishedName -split ',').Count }, Name |
    Select-Object Name, ProtectedFromAccidentalDeletion, DistinguishedName
Add-Section -Title 'Unités d''organisation' -CsvName 'ous' -Data $ous

$computers = Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion, IPv4Address, LastLogonDate, whenCreated |
    Sort-Object Name |
    Select-Object Name, OperatingSystem, OperatingSystemVersion, IPv4Address, LastLogonDate, whenCreated,
        @{ n = 'OU'; e = { ($_.DistinguishedName -split ',', 2)[1] } }
Add-Section -Title 'Ordinateurs du domaine' -CsvName 'computers' -Data $computers `
    -Note "$(@($computers | Where-Object { $_.Name -in $config.Members.Name }).Count) machine(s) membre(s) attendue(s) sur $($config.Members.Count) présentes dans l'annuaire."

$users = Get-ADUser -SearchBase $rootDN -Filter * -Properties Department, Title, Enabled, LastLogonDate, PasswordLastSet |
    Sort-Object Department, SamAccountName |
    Select-Object SamAccountName, Name, Department, Title, Enabled, LastLogonDate, PasswordLastSet,
        @{ n = 'OU'; e = { (($_.DistinguishedName -split ',', 2)[1] -split ',')[0] -replace '^OU=' } }
Add-Section -Title 'Utilisateurs' -CsvName 'users' -Data $users

Add-Section -Title 'Groupes (AGDLP)' -CsvName 'groups' -Data @(Get-LabGroupMembership)

$gpos = Get-GPO -All | Sort-Object DisplayName | ForEach-Object {
    [xml]$xml = Get-GPOReport -Guid $_.Id -ReportType Xml
    Get-GPOReport -Guid $_.Id -ReportType Html -Path (Join-Path -Path $outDir -ChildPath "gpo/$($_.DisplayName).html")
    $links = @($xml.GPO.LinksTo | ForEach-Object { $_.SOMPath })
    [pscustomobject]@{
        Nom          = $_.DisplayName
        Statut       = $_.GpoStatus
        Liens        = $links -join ' ; '
        VersionOrdi  = $_.Computer.DSVersion
        VersionUser  = $_.User.DSVersion
        Modifiee     = $_.ModificationTime
    }
}
Add-Section -Title 'Stratégies de groupe' -CsvName 'gpos' -Data $gpos -Note 'Rapports détaillés dans le dossier gpo/.'

$pp = Get-ADDefaultDomainPasswordPolicy
$fgpp = Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {
    [pscustomobject]@{
        Politique = $_.Name; Longueur = $_.MinPasswordLength; Historique = $_.PasswordHistoryCount
        AgeMax = $_.MaxPasswordAge; Verrouillage = $_.LockoutThreshold
        AppliqueeA = (@(Get-ADFineGrainedPasswordPolicySubject -Identity $_.Name).Name) -join ', '
    }
}
$policies = @([pscustomobject]@{
        Politique = 'Domaine (par défaut)'; Longueur = $pp.MinPasswordLength; Historique = $pp.PasswordHistoryCount
        AgeMax = $pp.MaxPasswordAge; Verrouillage = $pp.LockoutThreshold; AppliqueeA = 'Tous les comptes'
    }) + @($fgpp)
Add-Section -Title 'Politiques de mots de passe' -CsvName 'password-policies' -Data $policies

Add-Section -Title 'Membres des groupes à privilèges' -CsvName 'privileged' -Data @(Get-LabPrivilegedMember)
Add-Section -Title 'Comptes à risque' -CsvName 'account-risks' -Data @(Get-LabAccountRisk) `
    -Note 'Le compte Administrateur intégré apparaît souvent ici : désactive-le une fois les comptes adm-* opérationnels.'

if (Get-Command -Name Get-DnsServerZone -ErrorAction SilentlyContinue) {
    $zones = Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated } |
        Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone, DynamicUpdate
    Add-Section -Title 'Zones DNS' -CsvName 'dns-zones' -Data $zones
    $records = Get-DnsServerResourceRecord -ZoneName $fqdn -RRType A |
        Where-Object { $_.HostName -notlike '*DnsZones*' -and $_.HostName -ne '@' } |
        Select-Object HostName, @{ n = 'IPv4'; e = { $_.RecordData.IPv4Address.IPAddressToString } }, Timestamp
    Add-Section -Title "Enregistrements A ($fqdn)" -CsvName 'dns-records' -Data $records
}

if (Get-Command -Name Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
    $scopes = Get-DhcpServerv4Scope | ForEach-Object {
        $stats = Get-DhcpServerv4ScopeStatistics -ScopeId $_.ScopeId
        $opts = Get-DhcpServerv4OptionValue -ScopeId $_.ScopeId
        [pscustomobject]@{
            Etendue = $_.ScopeId; Nom = $_.Name; Debut = $_.StartRange; Fin = $_.EndRange; Etat = $_.State
            Baux = $stats.InUse; Libres = $stats.Free
            Routeur = (($opts | Where-Object OptionId -EQ 3).Value) -join ','
            DNS = (($opts | Where-Object OptionId -EQ 6).Value) -join ','
        }
    }
    Add-Section -Title 'DHCP — étendues' -CsvName 'dhcp-scopes' -Data $scopes
    $leases = Get-DhcpServerv4Scope | ForEach-Object { Get-DhcpServerv4Lease -ScopeId $_.ScopeId } |
        Select-Object IPAddress, HostName, ClientId, AddressState, LeaseExpiryTime
    Add-Section -Title 'DHCP — baux attribués' -CsvName 'dhcp-leases' -Data $leases
}

Add-Section -Title 'Santé du contrôleur de domaine' -CsvName 'health' -Data @(Test-LabDomainHealth)

# --- Assemblage HTML ------------------------------------------------------------------------
$index = Export-LabHtmlReport -Directory $outDir -Title "Rapport Active Directory — $fqdn" -Sections $sections
Write-LabLog "Rapport généré : $index" -Level OK
