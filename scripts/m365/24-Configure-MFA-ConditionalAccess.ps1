#Requires -Version 5.1

<#
.SYNOPSIS
    Met en place la MFA par accès conditionnel, avec un compte d'urgence (break-glass) exclu.

.DESCRIPTION
    Ordre volontaire, pour ne jamais se verrouiller hors du tenant :
    1. Compte d'urgence bg-admin (cloud, Administrateur général, mot de passe long aléatoire)
    2. Méthodes d'authentification : Microsoft Authenticator activé pour tous
    3. Désactivation des paramètres de sécurité par défaut (incompatibles avec l'accès conditionnel)
    4. Stratégies d'accès conditionnel, créées en mode « rapport uniquement » :
         CA001  MFA pour tous les utilisateurs, toutes les applications
         CA002  Blocage de l'authentification héritée (POP/IMAP/SMTP basique, EAS)
         CA003  MFA pour inscrire ou joindre un appareil à Entra ID
    5. Avec -Enforce : passage des stratégies en mode « activé »

    Vérifie les journaux de connexion (onglet « Rapport uniquement ») avant d'utiliser -Enforce.
    Accès conditionnel = Entra ID P1 (inclus dans E5 développeur et Business Premium).

.EXAMPLE
    .\24-Configure-MFA-ConditionalAccess.ps1            # création en rapport uniquement
    .\24-Configure-MFA-ConditionalAccess.ps1 -Enforce   # activation après vérification
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [switch]$Enforce
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabM365/LabM365.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$m365 = $config.M365
$tenant = $m365.TenantDomain

Connect-LabGraph -TenantDomain $tenant -Scopes @(
    'User.ReadWrite.All', 'Directory.ReadWrite.All', 'RoleManagement.ReadWrite.Directory',
    'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Policy.ReadWrite.AuthenticationMethod',
    'Application.Read.All'
) | Out-Null

# =====================================================================================
# 1. Compte d'urgence
# =====================================================================================
$bgUpn = "$($m365.BreakGlassUpn)@$tenant"
$bg = Get-LabGraphUser -UserPrincipalName $bgUpn
if (-not $bg -and $PSCmdlet.ShouldProcess($bgUpn, 'Créer le compte d''urgence')) {
    $password = New-LabPassword -Length 64
    $bg = Invoke-LabGraph -Method POST -Uri 'v1.0/users' -Body @{
        accountEnabled    = $true
        displayName       = 'Compte d''urgence (break-glass)'
        mailNickname      = $m365.BreakGlassUpn
        userPrincipalName = $bgUpn
        usageLocation     = $m365.UsageLocation
        passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $false }
        passwordPolicies  = 'DisablePasswordExpiration'
    }
    Export-LabSecret -FileName 'break-glass.csv' -Entry ([pscustomobject]@{ Compte = $bgUpn; MotDePasse = $password })
    Write-LabLog "Compte d'urgence créé : $bgUpn. Mot de passe dans output/secrets/break-glass.csv : imprime-le, range-le hors ligne, puis supprime le fichier." -Level WARN
    $bg = Wait-LabGraphObject -What $bgUpn -Probe { Get-LabGraphUser -UserPrincipalName $bgUpn }
}
elseif ($bg) { Write-LabLog "Compte d'urgence $bgUpn déjà présent" -Level SKIP }

if ($bg) {
    $gaRole = Get-LabRoleTemplateId -Role GlobalAdministrator
    $assignments = @(Invoke-LabGraph -Uri "v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($bg.id)'")
    if ($assignments | Where-Object roleDefinitionId -EQ $gaRole) {
        Write-LabLog "$bgUpn est déjà Administrateur général" -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess($bgUpn, 'Attribuer Administrateur général')) {
        Invoke-LabGraph -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{
            principalId      = $bg.id
            roleDefinitionId = $gaRole
            directoryScopeId = '/'
        } | Out-Null
        Write-LabLog "$bgUpn : rôle Administrateur général attribué" -Level OK
    }
}

# =====================================================================================
# 2. Méthodes d'authentification
# =====================================================================================
if ($PSCmdlet.ShouldProcess('Microsoft Authenticator', 'Activer pour tous les utilisateurs')) {
    try {
        Invoke-LabGraph -Method PATCH -Uri 'v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/MicrosoftAuthenticator' -Body @{
            '@odata.type'  = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethodConfiguration'
            state          = 'enabled'
            includeTargets = @(@{ targetType = 'group'; id = 'all_users'; isRegistrationRequired = $false; authenticationMode = 'any' })
        } | Out-Null
        Write-LabLog 'Microsoft Authenticator activé pour tous (notifications avec correspondance de nombre)' -Level OK
    }
    catch {
        Write-LabLog "Méthode Authenticator : $(Get-LabGraphErrorMessage $_)" -Level WARN
    }
}

# =====================================================================================
# 3. Paramètres de sécurité par défaut
# =====================================================================================
$sd = Invoke-LabGraph -Uri 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
if ($sd.isEnabled -and $PSCmdlet.ShouldProcess('Paramètres de sécurité par défaut', 'Désactiver (remplacés par l''accès conditionnel)')) {
    Invoke-LabGraph -Method PATCH -Uri 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy' -Body @{ isEnabled = $false } | Out-Null
    Write-LabLog 'Paramètres de sécurité par défaut désactivés — les stratégies CA prennent le relais' -Level WARN
}
elseif (-not $sd.isEnabled) { Write-LabLog 'Paramètres de sécurité par défaut déjà désactivés' -Level SKIP }

# =====================================================================================
# 4. Stratégies d'accès conditionnel
# =====================================================================================
if (-not $bg -and -not $WhatIfPreference) {
    throw 'Compte d''urgence introuvable : aucune stratégie CA ne sera créée sans exclusion (risque de verrouillage).'
}
$state = if ($Enforce) { 'enabled' } else { 'enabledForReportingButNotEnforced' }
$exclude = if ($bg) { @($bg.id) } else { @() }

$policies = @(
    @{
        displayName   = 'CA001-Tous-Utilisateurs-MFA'
        conditions    = @{
            users          = @{ includeUsers = @('All'); excludeUsers = $exclude }
            applications   = @{ includeApplications = @('All') }
            clientAppTypes = @('all')
        }
        grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
    }
    @{
        displayName   = 'CA002-Tous-Bloquer-Authentification-Heritee'
        conditions    = @{
            users          = @{ includeUsers = @('All'); excludeUsers = $exclude }
            applications   = @{ includeApplications = @('All') }
            clientAppTypes = @('exchangeActiveSync', 'other')
        }
        grantControls = @{ operator = 'OR'; builtInControls = @('block') }
    }
    @{
        displayName   = 'CA003-Tous-MFA-Inscription-Appareil'
        conditions    = @{
            users          = @{ includeUsers = @('All'); excludeUsers = $exclude }
            applications   = @{ includeUserActions = @('urn:user:registerdevice') }
            clientAppTypes = @('all')
        }
        grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
    }
)

$existing = @(Invoke-LabGraph -Uri 'v1.0/identity/conditionalAccess/policies?$select=id,displayName,state')
foreach ($p in $policies) {
    $current = $existing | Where-Object displayName -EQ $p.displayName
    $body = $p.Clone()
    $body.state = $state
    try {
        if (-not $current) {
            if ($PSCmdlet.ShouldProcess($p.displayName, "Créer ($state)")) {
                Invoke-LabGraph -Method POST -Uri 'v1.0/identity/conditionalAccess/policies' -Body $body | Out-Null
                Write-LabLog "$($p.displayName) créée [$state]" -Level OK
            }
        }
        elseif ($current.state -ne $state -or $Enforce) {
            if ($PSCmdlet.ShouldProcess($p.displayName, "Mettre à jour ($state)")) {
                Invoke-LabGraph -Method PATCH -Uri "v1.0/identity/conditionalAccess/policies/$($current.id)" -Body $body | Out-Null
                Write-LabLog "$($p.displayName) mise à jour [$($current.state) -> $state]" -Level OK
            }
        }
        else { Write-LabLog "$($p.displayName) déjà présente [$($current.state)]" -Level SKIP }
    }
    catch {
        Write-LabLog "$($p.displayName) : $(Get-LabGraphErrorMessage $_)" -Level ERROR
    }
}

if (-not $Enforce) {
    Write-LabLog 'Stratégies en RAPPORT UNIQUEMENT. Vérifie Entra > Journaux de connexion > Accès conditionnel, puis relance avec -Enforce.' -Level WARN
}
Write-LabLog 'Réglage manuel : Entra > Appareils > Paramètres > « Exiger MFA pour inscrire ou joindre des appareils » = Non (CA003 prend le relais).' -Level INFO
Write-LabLog 'Étape suivante : 25-Configure-Intune.ps1' -Level OK
