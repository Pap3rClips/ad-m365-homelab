#Requires -Version 5.1

<#
.SYNOPSIS
    Installe les modules nécessaires à la partie Microsoft 365, pour l'utilisateur courant.

.DESCRIPTION
    - Microsoft.Graph.Authentication   : Entra ID, accès conditionnel, Intune (via Invoke-MgGraphRequest)
    - ExchangeOnlineManagement         : Exchange Online
    - Microsoft.Online.SharePoint.PowerShell : SharePoint Online (Windows PowerShell 5.1)
    À lancer sur le poste d'administration (CLT02 ou ton PC hôte), pas sur le DC.

.EXAMPLE
    .\20-Install-M365Modules.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess('NuGet', 'Install-PackageProvider')) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
}

$modules = @(
    @{ Name = 'Microsoft.Graph.Authentication';          MinimumVersion = '2.10.0' }
    @{ Name = 'ExchangeOnlineManagement';                MinimumVersion = '3.4.0' }
    @{ Name = 'Microsoft.Online.SharePoint.PowerShell';  MinimumVersion = '16.0.24000.0' }
)

foreach ($m in $modules) {
    $installed = Get-Module -ListAvailable -Name $m.Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($installed -and $installed.Version -ge [version]$m.MinimumVersion) {
        Write-LabLog "$($m.Name) $($installed.Version) déjà installé" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($m.Name, 'Install-Module -Scope CurrentUser')) {
        Install-Module -Name $m.Name -MinimumVersion $m.MinimumVersion -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        Write-LabLog "$($m.Name) installé" -Level OK
    }
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-LabLog 'Le script SharePoint (23) s''exécute dans Windows PowerShell 5.1 (powershell.exe), les autres dans pwsh ou powershell.' -Level INFO
}
