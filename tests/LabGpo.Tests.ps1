#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../modules/LabGpo/LabGpo.psm1') -Force
}

Describe 'Merge-LabGpoExtension' {
    It 'ajoute une extension à une valeur vide' {
        Merge-LabGpoExtension -Existing '' -Add '[{A}{1}]' | Should -Be '[{A}{1}]'
    }
    It 'trie les extensions et fusionne les outils d''une même extension' {
        Merge-LabGpoExtension -Existing '[{B}{2}]' -Add '[{A}{1}][{B}{1}]' | Should -Be '[{A}{1}][{B}{1}{2}]'
    }
    It 'est idempotente' {
        $once = Merge-LabGpoExtension -Existing '[{B}{2}]' -Add '[{A}{1}]'
        Merge-LabGpoExtension -Existing $once -Add '[{A}{1}]' | Should -Be $once
    }
    It 'conserve l''extension Registry.pol existante en ajoutant la sécurité' {
        $registry = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
        $security = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
        Merge-LabGpoExtension -Existing $registry -Add $security | Should -Be ($registry + $security)
    }
}

Describe 'New-LabSecurityTemplate' {
    BeforeAll {
        $content = New-LabSecurityTemplate -Sections ([ordered]@{
                'System Access'    = [ordered]@{ EnableGuestAccount = 0 }
                'Group Membership' = [ordered]@{ '*S-1-5-21-1-2-3-1105__Memberof' = '*S-1-5-32-544' }
            })
    }
    It 'commence par les en-têtes Unicode et Version' {
        $content | Should -Match '^\[Unicode\]\r\nUnicode=yes\r\n\[Version\]\r\nsignature="\$CHICAGO\$"'
    }
    It 'écrit les sections dans l''ordre fourni' {
        $content.IndexOf('[System Access]') | Should -BeLessThan $content.IndexOf('[Group Membership]')
    }
    It 'utilise la forme « Membre de » pour ne pas écraser les Administrateurs locaux' {
        $content | Should -Match '__Memberof = \*S-1-5-32-544'
        $content | Should -Not -Match '__Members ='
    }
}

Describe 'New-LabDrivesXml' {
    BeforeAll {
        $xmlText = New-LabDrivesXml -Drives @(
            [pscustomobject]@{ Letter = 'k'; Path = '\\SRV01\Comptabilite'; Label = 'Compta & Co'
                Groups = @(@{ Name = 'CORP\GG-A'; Sid = 'S-1-5-21-1' }, @{ Name = 'CORP\GG-B'; Sid = 'S-1-5-21-2' }) }
            [pscustomobject]@{ Letter = 'P'; Path = '\\SRV01\Commun'; Label = 'Commun'; Groups = @() }
        )
        $xml = [xml]$xmlText
    }
    It 'produit un XML valide avec un lecteur par entrée' {
        @($xml.Drives.Drive).Count | Should -Be 2
    }
    It 'met la lettre en majuscule' {
        $xml.Drives.Drive[0].name | Should -Be 'K:'
    }
    It 'échappe les caractères spéciaux' {
        $xml.Drives.Drive[0].Properties.label | Should -Be 'Compta & Co'
    }
    It 'combine les groupes en OU' {
        $filters = @($xml.Drives.Drive[0].Filters.FilterGroup)
        $filters[0].bool | Should -Be 'AND'
        $filters[1].bool | Should -Be 'OR'
    }
    It 'n''ajoute pas de filtre sans groupe' {
        $xml.Drives.Drive[1].SelectSingleNode('Filters') | Should -BeNullOrEmpty
    }
}
