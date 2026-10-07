#Requires -Version 5.1

<#
.SYNOPSIS
    Installe et autorise le serveur DHCP sur le DC, puis crée l'étendue du LAN.

.DESCRIPTION
    - Rôle DHCP + groupes de sécurité locaux (DHCP Administrators / Users)
    - Autorisation du serveur dans Active Directory
    - Étendue, exclusions, réservations et options (routeur, DNS, suffixe)
    - Mises à jour DNS dynamiques effectuées par le serveur DHCP pour les clients
    - Suppression de l'alerte « configuration post-installation » du Gestionnaire de serveur

.EXAMPLE
    .\04-Configure-DHCP.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$dhcp = $config.Dhcp
$dc   = $config.DomainController
$fqdn = $config.Domain.FQDN

# --- Rôle ------------------------------------------------------------------------
if (-not (Get-WindowsFeature -Name DHCP).Installed) {
    if ($PSCmdlet.ShouldProcess('DHCP', 'Install-WindowsFeature')) {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        Write-LabLog 'Rôle DHCP installé' -Level OK
    }
}
else { Write-LabLog 'Rôle DHCP déjà installé' -Level SKIP }

Import-Module DhcpServer

if ($PSCmdlet.ShouldProcess('DHCP', 'Créer les groupes de sécurité DHCP')) {
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
    Restart-Service -Name DHCPServer
}

# --- Autorisation dans AD ----------------------------------------------------------
$serverFqdn = "$($dc.Name).$fqdn"
$authorized = Get-DhcpServerInDC | Where-Object { $_.IPAddress -eq $dc.IPAddress }
if ($authorized) {
    Write-LabLog 'Serveur DHCP déjà autorisé dans AD' -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($serverFqdn, 'Add-DhcpServerInDC')) {
    Add-DhcpServerInDC -DnsName $serverFqdn -IPAddress $dc.IPAddress
    Write-LabLog "Serveur DHCP $serverFqdn autorisé dans AD" -Level OK
}

# Masque l'assistant post-installation dans le Gestionnaire de serveur
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue

# --- Étendue -------------------------------------------------------------------------
$scopeId = $config.Network.NetworkId
$scope = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
if ($scope) {
    Write-LabLog "Étendue $scopeId déjà présente" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($scopeId, "Créer l'étendue $($dhcp.StartRange) - $($dhcp.EndRange)")) {
    Add-DhcpServerv4Scope -Name $dhcp.ScopeName -StartRange $dhcp.StartRange -EndRange $dhcp.EndRange `
        -SubnetMask $dhcp.SubnetMask -LeaseDuration ([timespan]$dhcp.LeaseDuration) -State Active
    Write-LabLog "Étendue $($dhcp.ScopeName) créée" -Level OK
}

if ($PSCmdlet.ShouldProcess($scopeId, 'Options 003/006/015')) {
    Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $config.Network.Gateway `
        -DnsServer $dc.IPAddress -DnsDomain $fqdn -Force
    Write-LabLog "Options : routeur $($config.Network.Gateway), DNS $($dc.IPAddress), suffixe $fqdn" -Level OK
}

# --- Exclusions ------------------------------------------------------------------------
$existingExclusions = @(Get-DhcpServerv4ExclusionRange -ScopeId $scopeId -ErrorAction SilentlyContinue)
foreach ($ex in $dhcp.Exclusions) {
    if ($existingExclusions | Where-Object { $_.StartRange -eq $ex.Start -and $_.EndRange -eq $ex.End }) {
        Write-LabLog "Exclusion $($ex.Start)-$($ex.End) déjà présente" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($scopeId, "Exclure $($ex.Start)-$($ex.End)")) {
        Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $ex.Start -EndRange $ex.End
        Write-LabLog "Exclusion $($ex.Start)-$($ex.End)" -Level OK
    }
}

# --- Réservations -------------------------------------------------------------------------
foreach ($res in $dhcp.Reservations) {
    if (Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue | Where-Object IPAddress -EQ $res.IPAddress) {
        Write-LabLog "Réservation $($res.IPAddress) déjà présente" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($res.Name, "Réserver $($res.IPAddress)")) {
        Add-DhcpServerv4Reservation -ScopeId $scopeId -IPAddress $res.IPAddress -ClientId $res.MacAddress `
            -Name $res.Name -Description 'Réservation lab'
        Write-LabLog "Réservation $($res.Name) -> $($res.IPAddress) ($($res.MacAddress))" -Level OK
    }
}

# --- DNS dynamique ---------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess('DHCP', 'Mises à jour DNS dynamiques')) {
    Set-DhcpServerv4DnsSetting -ComputerName $serverFqdn -DynamicUpdates Always `
        -DeleteDnsRRonLeaseExpiry $true -UpdateDnsRRForOlderClients $true
    Write-LabLog 'Mises à jour DNS dynamiques activées' -Level OK
}

Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange, EndRange, State -AutoSize
Write-LabLog 'DHCP prêt. Étape suivante : 05-Create-OUStructure.ps1' -Level OK
