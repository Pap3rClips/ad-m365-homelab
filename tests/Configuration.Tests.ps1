#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Vérifie la cohérence de config/lab.psd1 et des CSV avant tout déploiement :
    une faute de frappe dans un nom de groupe est détectée ici plutôt que sur le DC.
#>

BeforeDiscovery {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $scripts = Get-ChildItem -Path (Join-Path -Path $root -ChildPath 'scripts') -Recurse -Filter '*.ps1' |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $root -ChildPath 'modules/LabCommon/LabCommon.psm1') -Force
    $config = Import-LabConfig -Path (Join-Path -Path $root -ChildPath 'config/lab.psd1')
    $users  = Import-Csv -Path (Join-Path -Path $root -ChildPath 'data/users.csv')
    $admins = Import-Csv -Path (Join-Path -Path $root -ChildPath 'data/admins.csv')
    $groupNames = @($config.Groups | ForEach-Object { $_.Name })

    function ConvertTo-IPv4Int([string]$Ip) {
        $b = ([Net.IPAddress]$Ip).GetAddressBytes(); [array]::Reverse($b); [BitConverter]::ToUInt32($b, 0)
    }
    function Test-InNetwork([string]$Ip) {
        $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $config.Network.PrefixLength))
        ((ConvertTo-IPv4Int $Ip) -band $mask) -eq (ConvertTo-IPv4Int $config.Network.NetworkId)
    }
}

Describe 'Réseau' {
    It 'place le DC, la passerelle et les serveurs dans le sous-réseau' {
        Test-InNetwork $config.DomainController.IPAddress | Should -BeTrue
        Test-InNetwork $config.Network.Gateway | Should -BeTrue
        $config.Members | Where-Object { $_.ContainsKey('IPAddress') } | ForEach-Object { Test-InNetwork $_.IPAddress | Should -BeTrue }
    }
    It 'n''inclut aucune IP fixe dans l''étendue DHCP' {
        $start = ConvertTo-IPv4Int $config.Dhcp.StartRange
        $end   = ConvertTo-IPv4Int $config.Dhcp.EndRange
        $fixed = @($config.DomainController.IPAddress, $config.Network.Gateway) +
            @($config.Members | Where-Object { $_.ContainsKey('IPAddress') } | ForEach-Object { $_.IPAddress })
        foreach ($ip in $fixed) {
            $n = ConvertTo-IPv4Int $ip
            ($n -ge $start -and $n -le $end) | Should -BeFalse -Because "$ip est une adresse fixe"
        }
    }
    It 'place les réservations dans l''étendue' {
        foreach ($r in $config.Dhcp.Reservations) {
            $n = ConvertTo-IPv4Int $r.IPAddress
            ($n -ge (ConvertTo-IPv4Int $config.Dhcp.StartRange) -and $n -le (ConvertTo-IPv4Int $config.Dhcp.EndRange)) | Should -BeTrue
        }
    }
    It 'déclare exactement trois machines jointes au domaine' {
        $config.Members.Count | Should -Be 3
    }
    It 'aligne la MAC Hyper-V de CLT02 sur la réservation DHCP' {
        $vmMac = ($config.HyperV.VMs | Where-Object Name -EQ 'CLT02').MacAddress
        $resMac = ($config.Dhcp.Reservations | Where-Object Name -EQ 'CLT02').MacAddress -replace '-', ''
        $vmMac | Should -Be $resMac
    }
}

Describe 'Annuaire' {
    It 'définit une OU pour chaque service utilisé dans users.csv' {
        foreach ($dept in ($users.Department | Sort-Object -Unique)) {
            $config.OrganizationalUnits | Should -Contain "Utilisateurs/$dept"
        }
    }
    It 'définit une OU pour chaque machine membre' {
        foreach ($m in $config.Members) { $config.OrganizationalUnits | Should -Contain "Ordinateurs/$($m.OU)" }
    }
    It 'déclare les OU parentes avant les enfants' {
        for ($i = 0; $i -lt $config.OrganizationalUnits.Count; $i++) {
            $ou = $config.OrganizationalUnits[$i]
            if ($ou -match '/') {
                $parent = $ou.Substring(0, $ou.LastIndexOf('/'))
                $config.OrganizationalUnits.IndexOf($parent) | Should -BeLessThan $i
            }
        }
    }
    It 'ne référence que des groupes existants' {
        $referenced = @($users.Groups -split ';') + @($admins.Groups -split ';') +
            @($config.GroupNesting | ForEach-Object { $_.Member; $_.Group }) +
            @($config.FileShares | ForEach-Object { $_.Modify; $_.Read; $_.DriveGroups }) +
            @($config.PasswordPolicy.AdminFGPP.AppliesTo)
        foreach ($g in $referenced | Where-Object { $_ -and $_ -notlike '@*' } | Sort-Object -Unique) {
            $groupNames | Should -Contain $g
        }
    }
    It 'applique AGDLP : un groupe global n''est jamais imbriqué dans un autre global' {
        foreach ($n in $config.GroupNesting) {
            ($config.Groups | Where-Object Name -EQ $n.Group).Scope | Should -Be 'DomainLocal'
        }
    }
    It 'génère des identifiants uniques' {
        $sams = $users | ForEach-Object { ConvertTo-LabSamAccountName -GivenName $_.GivenName -Surname $_.Surname }
        ($sams | Sort-Object -Unique).Count | Should -Be $sams.Count
    }
    It 'préfixe les comptes d''administration par adm-' {
        $admins.SamAccountName | ForEach-Object { $_ | Should -Match '^adm-' }
    }
    It 'impose une FGPP admin plus stricte que la politique du domaine' {
        $config.PasswordPolicy.AdminFGPP.MinPasswordLength | Should -BeGreaterThan $config.PasswordPolicy.MinPasswordLength
    }
}

Describe 'Microsoft 365' {
    It 'cible Intune sur un groupe dynamique d''appareils déclaré' {
        $target = $config.M365.DynamicGroups | Where-Object Name -EQ $config.M365.Intune.TargetGroup
        $target | Should -Not -BeNullOrEmpty
        $target.Devices | Should -BeTrue
    }
    It 'associe chaque site d''équipe à un service existant' {
        foreach ($ts in $config.M365.TeamSites) { $users.Department | Should -Contain $ts.Department }
    }
    It 'donne au moins un membre licencié à chaque boîte partagée' {
        foreach ($sm in $config.M365.SharedMailboxes) {
            foreach ($dept in $sm.Members) {
                @($users | Where-Object { $_.Department -eq $dept -and $_.M365 -eq 'true' }).Count | Should -BeGreaterThan 0
            }
        }
    }
}

Describe 'Script <Name>' -ForEach $scripts {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    }
    It 'se parse sans erreur' {
        $errors | Should -BeNullOrEmpty
    }
    It 'documente son objectif (.SYNOPSIS)' {
        $ast.GetHelpContent().Synopsis | Should -Not -BeNullOrEmpty
    }
    It 'est encodé en UTF-8 avec BOM (lisible par Windows PowerShell 5.1)' {
        $bytes = [IO.File]::ReadAllBytes($Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
    }
    It 'ne contient aucun mot de passe en dur' {
        Get-Content -Path $Path -Raw | Should -Not -Match '(?i)password\s*=\s*[''"][^''"$]{6,}[''"]'
    }
}
