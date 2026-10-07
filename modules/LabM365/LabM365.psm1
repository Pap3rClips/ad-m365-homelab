#Requires -Version 5.1

<#
.SYNOPSIS
    Accès Microsoft Graph du lab : connexion, appels REST avec pagination et recherche d'objets.

.DESCRIPTION
    Les scripts M365 appellent l'API Graph via Invoke-MgGraphRequest (module
    Microsoft.Graph.Authentication uniquement) plutôt que via les ~40 sous-modules du SDK :
    installation légère, et chaque appel correspond 1:1 à la documentation REST de Microsoft.
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../LabCommon/LabCommon.psm1')

# Rôles Entra (identifiants de modèles, identiques dans tous les tenants)
$script:RoleTemplates = @{
    GlobalAdministrator = '62e90394-69f5-4237-9190-012177145e10'
    IntuneAdministrator = '3a2c62db-5318-420d-8d74-23affee5d9d5'
}

function Get-LabRoleTemplateId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('GlobalAdministrator', 'IntuneAdministrator')][string]$Role)
    $script:RoleTemplates[$Role]
}

function Connect-LabGraph {
    <#
    .SYNOPSIS
        Ouvre une session Graph déléguée avec les étendues demandées et vérifie que le tenant
        connecté est bien celui de lab.psd1 (évite d'agir sur le mauvais tenant).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Scopes,
        [Parameter(Mandatory)][string]$TenantDomain
    )
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Module Microsoft.Graph.Authentication absent : lance scripts/m365/20-Install-M365Modules.ps1'
    }
    Import-Module Microsoft.Graph.Authentication

    $ctx = Get-MgContext
    $missing = if ($ctx) { @($Scopes | Where-Object { $_ -notin $ctx.Scopes }) } else { $Scopes }
    if (-not $ctx -or $missing.Count -gt 0) {
        Connect-MgGraph -Scopes $Scopes -TenantId $TenantDomain -NoWelcome -ContextScope Process
    }

    $org = Invoke-LabGraph -Uri 'v1.0/organization?$select=id,displayName,verifiedDomains'
    $domains = @($org.verifiedDomains | ForEach-Object { $_.name })
    if ($TenantDomain -notin $domains) {
        Disconnect-MgGraph | Out-Null
        throw "Le tenant connecté ($($org.displayName)) ne possède pas le domaine $TenantDomain. Vérifie M365.TenantDomain dans lab.psd1."
    }
    Write-LabLog "Connecté à Graph : $($org.displayName) ($TenantDomain) en tant que $((Get-MgContext).Account)" -Level OK
    $org
}

function Invoke-LabGraph {
    <#
    .SYNOPSIS
        Appel Graph ; en GET, suit automatiquement @odata.nextLink et renvoie tous les éléments.
    .EXAMPLE
        Invoke-LabGraph -Uri 'v1.0/users?$select=id,userPrincipalName'
        Invoke-LabGraph -Method POST -Uri 'v1.0/groups' -Body @{ displayName = 'X'; ... }
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body
    )
    $full = if ($Uri -match '^https://') { $Uri } else { "https://graph.microsoft.com/$($Uri.TrimStart('/'))" }
    $params = @{ Method = $Method; Uri = $full; OutputType = 'PSObject'; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $params.ContentType = 'application/json'
    }

    if ($Method -ne 'GET') { return Invoke-MgGraphRequest @params }

    $response = Invoke-MgGraphRequest @params
    if ($null -eq $response) { return }
    if (-not ($response.PSObject.Properties.Name -contains 'value')) { return $response }
    $response.value
    while ($response.PSObject.Properties.Name -contains '@odata.nextLink' -and $response.'@odata.nextLink') {
        $params.Uri = $response.'@odata.nextLink'
        $response = Invoke-MgGraphRequest @params
        $response.value
    }
}

function ConvertTo-LabODataLiteral {
    <# .SYNOPSIS Prépare une valeur pour un filtre OData : quotes doublées puis encodage URL. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Value)
    [uri]::EscapeDataString($Value.Replace("'", "''"))
}

function Get-LabGraphUser {
    <# .SYNOPSIS Renvoie l'utilisateur par UPN, ou $null s'il n'existe pas. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [string]$Select = 'id,displayName,userPrincipalName,department,accountEnabled,usageLocation'
    )
    $filter = "userPrincipalName eq '$(ConvertTo-LabODataLiteral $UserPrincipalName)'"
    @(Invoke-LabGraph -Uri "v1.0/users?`$filter=$filter&`$select=$Select") | Select-Object -First 1
}

function Get-LabGraphGroup {
    <# .SYNOPSIS Renvoie le groupe par nom d'affichage, ou $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DisplayName)
    $filter = "displayName eq '$(ConvertTo-LabODataLiteral $DisplayName)'"
    $groups = @(Invoke-LabGraph -Uri "v1.0/groups?`$filter=$filter&`$select=id,displayName,groupTypes,mailNickname,membershipRule")
    if ($groups.Count -gt 1) { throw "Plusieurs groupes nommés '$DisplayName' : renomme les doublons." }
    $groups | Select-Object -First 1
}

function Add-LabGraphGroupMember {
    <# .SYNOPSIS Ajoute un objet à un groupe ; renvoie $false s'il en était déjà membre. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$MemberId
    )
    $existing = @(Invoke-LabGraph -Uri "v1.0/groups/$GroupId/members?`$select=id" | ForEach-Object { $_.id })
    if ($MemberId -in $existing) { return $false }
    if ($PSCmdlet.ShouldProcess($GroupId, "Ajouter $MemberId")) {
        Invoke-LabGraph -Method POST -Uri "v1.0/groups/$GroupId/members/`$ref" `
            -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$MemberId" } | Out-Null
    }
    $true
}

function Wait-LabGraphObject {
    <#
    .SYNOPSIS
        Attend qu'un objet tout juste créé soit visible (réplication Entra ID : quelques secondes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Probe,
        [int]$TimeoutSeconds = 120,
        [string]$What = 'objet'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = try { & $Probe } catch { $null }
        if ($result) { return $result }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "$What toujours introuvable après $TimeoutSeconds s."
}

function Get-LabGraphErrorMessage {
    <# .SYNOPSIS Extrait le message utile d'une erreur Graph (corps JSON) pour l'afficher clairement. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)
    $raw = if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $ErrorRecord.ErrorDetails.Message } else { $ErrorRecord.Exception.Message }
    try {
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        "$($json.error.code) : $($json.error.message)"
    }
    catch { $raw }
}

Export-ModuleMember -Function Get-LabRoleTemplateId, Connect-LabGraph, Invoke-LabGraph, ConvertTo-LabODataLiteral,
    Get-LabGraphUser, Get-LabGraphGroup, Add-LabGraphGroupMember, Wait-LabGraphObject, Get-LabGraphErrorMessage
