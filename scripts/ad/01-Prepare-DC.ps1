#Requires -Version 5.1

<#
.SYNOPSIS
    Prépare le futur contrôleur de domaine : nom, IP statique, DNS local, fuseau horaire.

.DESCRIPTION
    À lancer sur la VM Windows Server fraîchement installée, en administrateur local.
    Le script est idempotent : il ne modifie que ce qui diffère de la configuration.
    Un redémarrage est proposé si le nom de la machine change.

.EXAMPLE
    .\01-Prepare-DC.ps1 -WhatIf
    .\01-Prepare-DC.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }

$net = $config.Network
$dc  = $config.DomainController

# --- Adresse IP statique -----------------------------------------------------
$adapter = Get-NetAdapter -Name $net.InterfaceAlias -ErrorAction SilentlyContinue
if (-not $adapter) {
    $available = (Get-NetAdapter | Where-Object Status -EQ 'Up').Name -join ', '
    throw "Carte '$($net.InterfaceAlias)' introuvable. Cartes actives : $available. Corrige Network.InterfaceAlias dans lab.psd1."
}

$currentIp = Get-NetIPAddress -InterfaceAlias $net.InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object PrefixOrigin -EQ 'Manual'

if ($currentIp.IPAddress -eq $dc.IPAddress) {
    Write-LabLog "IP statique déjà en place : $($dc.IPAddress)" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($net.InterfaceAlias, "Attribuer $($dc.IPAddress)/$($net.PrefixLength)")) {
    Set-NetIPInterface -InterfaceAlias $net.InterfaceAlias -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $net.InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false
    Get-NetRoute -InterfaceAlias $net.InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceAlias $net.InterfaceAlias -IPAddress $dc.IPAddress `
        -PrefixLength $net.PrefixLength -DefaultGateway $net.Gateway | Out-Null
    Write-LabLog "IP statique $($dc.IPAddress)/$($net.PrefixLength), passerelle $($net.Gateway)" -Level OK
}

# --- DNS : le DC pointe sur lui-même ------------------------------------------
# Adresse propre en premier, boucle locale en second (recommandation Microsoft pour un DC unique)
$dnsTarget = @($dc.IPAddress, '127.0.0.1')
$dnsCurrent = (Get-DnsClientServerAddress -InterfaceAlias $net.InterfaceAlias -AddressFamily IPv4).ServerAddresses
if ((@($dnsCurrent) -join ',') -eq ($dnsTarget -join ',')) {
    Write-LabLog 'Serveurs DNS déjà configurés' -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($net.InterfaceAlias, "DNS = $($dnsTarget -join ', ')")) {
    Set-DnsClientServerAddress -InterfaceAlias $net.InterfaceAlias -ServerAddresses $dnsTarget
    Write-LabLog "DNS client : $($dnsTarget -join ', ')" -Level OK
}

# --- Fuseau horaire ------------------------------------------------------------
if ((Get-TimeZone).Id -ne 'Romance Standard Time' -and $PSCmdlet.ShouldProcess('Système', 'Fuseau horaire Europe/Paris')) {
    Set-TimeZone -Id 'Romance Standard Time'
    Write-LabLog 'Fuseau horaire réglé sur Europe/Paris' -Level OK
}

# --- Nom de la machine -----------------------------------------------------------
if ($env:COMPUTERNAME -eq $dc.Name) {
    Write-LabLog "Nom déjà correct : $($dc.Name)" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Renommer en $($dc.Name)")) {
    Rename-Computer -NewName $dc.Name -Force
    Write-LabLog "Machine renommée en $($dc.Name) — redémarrage nécessaire" -Level WARN
    if ($PSCmdlet.ShouldContinue('Redémarrer maintenant ?', 'Redémarrage')) {
        Restart-Computer -Force
    }
}

Write-LabLog 'Préparation terminée. Étape suivante : 02-Install-ADDS.ps1' -Level OK
