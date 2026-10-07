#Requires -Version 5.1
#Requires -Modules DnsServer

<#
.SYNOPSIS
    Configure le DNS intégré à AD : zone inverse, redirecteurs, nettoyage, enregistrements statiques.

.DESCRIPTION
    - Zone de recherche inversée intégrée à AD (réplication domaine)
    - Redirecteurs vers des résolveurs publics
    - Vieillissement/nettoyage des enregistrements dynamiques (7 j + 7 j)
    - Enregistrements A + PTR pour les serveurs à IP fixe
    - Vérification des enregistrements SRV indispensables à AD

.EXAMPLE
    .\03-Configure-DNS.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$fqdn = $config.Domain.FQDN
$net  = $config.Network

# --- Zone inverse --------------------------------------------------------------
# 192.168.50.0/24 -> 50.168.192.in-addr.arpa
$octets = $net.NetworkId.Split('.')
$reverseZone = '{0}.{1}.{2}.in-addr.arpa' -f $octets[2], $octets[1], $octets[0]

if (Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue) {
    Write-LabLog "Zone inverse $reverseZone déjà présente" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($reverseZone, 'Add-DnsServerPrimaryZone')) {
    Add-DnsServerPrimaryZone -NetworkId "$($net.NetworkId)/$($net.PrefixLength)" `
        -ReplicationScope Domain -DynamicUpdate Secure
    Write-LabLog "Zone inverse $reverseZone créée (mises à jour sécurisées)" -Level OK
}

# --- Redirecteurs --------------------------------------------------------------
$currentForwarders = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.IPAddressToString })
if (($currentForwarders -join ',') -eq ($net.DnsForwarders -join ',')) {
    Write-LabLog 'Redirecteurs déjà configurés' -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess('Serveur DNS', "Redirecteurs $($net.DnsForwarders -join ', ')")) {
    Set-DnsServerForwarder -IPAddress $net.DnsForwarders -UseRootHint $true
    Write-LabLog "Redirecteurs : $($net.DnsForwarders -join ', ')" -Level OK
}

# --- Vieillissement / nettoyage -------------------------------------------------
if ($PSCmdlet.ShouldProcess('Serveur DNS', 'Activer le nettoyage (7 j / 7 j)')) {
    Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 `
        -RefreshInterval 7.00:00:00 -NoRefreshInterval 7.00:00:00 -ApplyOnAllZones
    Write-LabLog 'Nettoyage des enregistrements obsolètes activé' -Level OK
}

# --- Enregistrements des serveurs à IP fixe -------------------------------------
foreach ($member in $config.Members | Where-Object { $_.ContainsKey('IPAddress') -and $_.IPAddress }) {
    $existing = Get-DnsServerResourceRecord -ZoneName $fqdn -Name $member.Name -RRType A -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabLog "Enregistrement A $($member.Name) déjà présent" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess("$($member.Name).$fqdn", "A $($member.IPAddress) + PTR")) {
        Add-DnsServerResourceRecordA -ZoneName $fqdn -Name $member.Name -IPv4Address $member.IPAddress -CreatePtr
        Write-LabLog "A + PTR : $($member.Name).$fqdn -> $($member.IPAddress)" -Level OK
    }
}

# PTR du contrôleur de domaine (créé avant la zone inverse, donc absent)
$dcIp = $config.DomainController.IPAddress
$ptrName = $dcIp.Split('.')[3]
if (-not (Get-DnsServerResourceRecord -ZoneName $reverseZone -Name $ptrName -RRType Ptr -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($dcIp, 'Ajouter le PTR du DC')) {
        Add-DnsServerResourceRecordPtr -ZoneName $reverseZone -Name $ptrName `
            -PtrDomainName "$($config.DomainController.Name).$fqdn."
        Write-LabLog "PTR $dcIp -> $($config.DomainController.Name).$fqdn" -Level OK
    }
}

# --- Vérification des SRV AD ------------------------------------------------------
$srvChecks = "_ldap._tcp.dc._msdcs.$fqdn", "_kerberos._tcp.$fqdn", "_gc._tcp.$fqdn"
foreach ($srv in $srvChecks) {
    $answer = Resolve-DnsName -Name $srv -Type SRV -Server $dcIp -ErrorAction SilentlyContinue
    if ($answer) {
        Write-LabLog "SRV OK : $srv" -Level OK
    }
    else {
        Write-LabLog "SRV manquant : $srv (relance 'ipconfig /registerdns' puis 'Restart-Service Netlogon')" -Level WARN
    }
}

$external = Resolve-DnsName -Name 'www.microsoft.com' -Server $dcIp -ErrorAction SilentlyContinue
if ($external) { Write-LabLog 'Résolution externe via redirecteurs : OK' -Level OK }
else { Write-LabLog 'Résolution externe en échec : vérifie la passerelle et les redirecteurs' -Level WARN }
