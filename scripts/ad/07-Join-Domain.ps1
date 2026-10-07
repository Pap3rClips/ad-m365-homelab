#Requires -Version 5.1

<#
.SYNOPSIS
    Joint une machine membre (SRV01, CLT01, CLT02) au domaine, dans la bonne OU.

.DESCRIPTION
    À lancer SUR la machine à joindre, en administrateur local.
    1. Applique l'IP statique si la machine en a une dans lab.psd1 (serveurs)
    2. Pointe le DNS vers le contrôleur de domaine (indispensable pour trouver le domaine)
    3. Vérifie que le DC répond (DNS + LDAP)
    4. Renomme et joint la machine en une seule opération, directement dans son OU

    Copie le dépôt sur la machine (ou partage-le) avant de lancer le script.

.PARAMETER ComputerName
    Nom cible tel que déclaré dans la section Members de lab.psd1.

.EXAMPLE
    .\07-Join-Domain.ps1 -ComputerName CLT01
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [string]$ConfigPath,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$fqdn = $config.Domain.FQDN
$net  = $config.Network
$dcIp = $config.DomainController.IPAddress

$member = $config.Members | Where-Object { $_.Name -eq $ComputerName }
if (-not $member) {
    throw "$ComputerName absent de Members dans lab.psd1 (valeurs possibles : $(($config.Members.Name) -join ', '))"
}

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $fqdn) {
    Write-LabLog "$env:COMPUTERNAME est déjà membre de $fqdn" -Level SKIP
    return
}

# Carte réseau : celle de lab.psd1 si elle existe, sinon la première carte active
$alias = $net.InterfaceAlias
if (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) {
    $alias = (Get-NetAdapter | Where-Object Status -EQ 'Up' | Select-Object -First 1).Name
    Write-LabLog "Carte '$($net.InterfaceAlias)' introuvable, utilisation de '$alias'" -Level WARN
}

# --- IP statique (serveurs uniquement) ---------------------------------------------------
if ($member.ContainsKey('IPAddress') -and $member.IPAddress) {
    $current = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($current.IPAddress -ne $member.IPAddress -and $PSCmdlet.ShouldProcess($alias, "IP statique $($member.IPAddress)")) {
        Set-NetIPInterface -InterfaceAlias $alias -Dhcp Disabled
        $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $member.IPAddress -PrefixLength $net.PrefixLength `
            -DefaultGateway $net.Gateway | Out-Null
        Write-LabLog "IP statique $($member.IPAddress)" -Level OK
    }
}
else {
    Write-LabLog 'Poste client : adresse obtenue par DHCP' -Level INFO
}

# --- DNS vers le DC -------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($alias, "DNS = $dcIp")) {
    Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $dcIp
    Clear-DnsClientCache
}

# --- Tests de connectivité ----------------------------------------------------------------------
$srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$fqdn" -Type SRV -ErrorAction SilentlyContinue
if (-not $srv) {
    throw "Impossible de résoudre les SRV du domaine via $dcIp. Vérifie le réseau de la VM et le script 03."
}
if (-not (Test-NetConnection -ComputerName $dcIp -Port 389 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Le port LDAP 389 du DC ($dcIp) ne répond pas."
}
Write-LabLog "Contrôleur de domaine joignable ($dcIp)" -Level OK

# --- Jonction ---------------------------------------------------------------------------------------
$ouPath = ConvertTo-LabOUPath -RelativePath "Ordinateurs/$($member.OU)" -RootOU $config.Domain.RootOU -Fqdn $fqdn
if (-not $Credential) {
    # adm-lfontaine (GG-Admins-Postes) dispose de la délégation posée par le script 05.
    # Les comptes de Protected Users ne peuvent pas s'authentifier en NTLM : évite-les ici.
    $Credential = Get-Credential -Message "Compte délégué pour la jonction (ex. $($config.Domain.NetBIOS)\adm-lfontaine)"
}

$joinParams = @{
    DomainName = $fqdn
    OUPath     = $ouPath
    Credential = $Credential
    Force      = $true
}
if ($env:COMPUTERNAME -ne $ComputerName) { $joinParams.NewName = $ComputerName }

if ($PSCmdlet.ShouldProcess($ComputerName, "Joindre $fqdn dans $ouPath")) {
    Add-Computer @joinParams
    Write-LabLog "$ComputerName joint à $fqdn ($ouPath) — redémarrage" -Level OK
    Restart-Computer -Force
}
