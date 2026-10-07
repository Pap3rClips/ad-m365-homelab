#Requires -Version 5.1

<#
.SYNOPSIS
    Installe le rôle AD DS (avec DNS intégré) et crée une nouvelle forêt.

.DESCRIPTION
    Le mot de passe DSRM (mode restauration des services d'annuaire) est demandé
    de façon interactive : il n'est jamais stocké dans le dépôt.
    Le serveur redémarre automatiquement à la fin de la promotion.

.EXAMPLE
    .\02-Install-ADDS.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$domain = $config.Domain

if ($env:COMPUTERNAME -ne $config.DomainController.Name) {
    throw "Cette machine s'appelle $env:COMPUTERNAME au lieu de $($config.DomainController.Name). Lance d'abord 01-Prepare-DC.ps1."
}

# DomainRole 4 ou 5 = contrôleur de domaine (secondaire / principal)
if ((Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4) {
    Write-LabLog "Cette machine est déjà contrôleur de domaine de $((Get-CimInstance Win32_ComputerSystem).Domain)" -Level SKIP
    return
}

# --- Rôles ---------------------------------------------------------------------
foreach ($feature in 'AD-Domain-Services', 'DNS', 'RSAT-AD-Tools', 'GPMC') {
    if ((Get-WindowsFeature -Name $feature).Installed) {
        Write-LabLog "Rôle $feature déjà installé" -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess($feature, 'Install-WindowsFeature')) {
        Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
        Write-LabLog "Rôle $feature installé" -Level OK
    }
}

# --- Promotion -------------------------------------------------------------------
$dsrm = Read-Host -Prompt 'Mot de passe DSRM (à conserver hors ligne)' -AsSecureString

$params = @{
    DomainName                    = $domain.FQDN
    DomainNetbiosName             = $domain.NetBIOS
    ForestMode                    = $domain.ForestMode
    DomainMode                    = $domain.DomainMode
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    DatabasePath                  = 'C:\Windows\NTDS'
    LogPath                       = 'C:\Windows\NTDS'
    SysvolPath                    = 'C:\Windows\SYSVOL'
    SafeModeAdministratorPassword = $dsrm
    NoRebootOnCompletion          = $false
    Force                         = $true
}

Write-LabLog 'Test des prérequis de la forêt...'
$test = Test-ADDSForestInstallation @params -WarningAction SilentlyContinue
if ($test.Status -ne 'Success') {
    throw "Prérequis non satisfaits : $($test.Message)"
}

if ($PSCmdlet.ShouldProcess($domain.FQDN, 'Install-ADDSForest')) {
    Write-LabLog "Création de la forêt $($domain.FQDN) ($($domain.NetBIOS)) — le serveur va redémarrer" -Level WARN
    Install-ADDSForest @params -WarningAction SilentlyContinue
}
