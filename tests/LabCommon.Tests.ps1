#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../modules/LabCommon/LabCommon.psm1') -Force
}

Describe 'Get-LabDomainDN' {
    It 'convertit un FQDN en DN LDAP' {
        Get-LabDomainDN -Fqdn 'corp.hadrien.lab' | Should -Be 'DC=corp,DC=hadrien,DC=lab'
    }
}

Describe 'ConvertTo-LabOUPath' {
    It 'inverse le chemin relatif sous l''OU racine' {
        ConvertTo-LabOUPath -RelativePath 'Utilisateurs/IT' -RootOU 'LAB' -Fqdn 'corp.lab' |
            Should -Be 'OU=IT,OU=Utilisateurs,OU=LAB,DC=corp,DC=lab'
    }
    It 'renvoie l''OU racine pour un chemin vide' {
        ConvertTo-LabOUPath -RelativePath '' -RootOU 'LAB' -Fqdn 'corp.lab' | Should -Be 'OU=LAB,DC=corp,DC=lab'
    }
}

Describe 'ConvertTo-LabSamAccountName' {
    It 'supprime accents, espaces et tirets' {
        ConvertTo-LabSamAccountName -GivenName 'Inès' -Surname 'Le Garnier-Évrard' | Should -Be 'ilegarnierevrard'
    }
    It 'tronque à 20 caractères' {
        (ConvertTo-LabSamAccountName -GivenName 'Jean' -Surname 'Abcdefghijklmnopqrstuvwxyz').Length | Should -Be 20
    }
    It 'gère les apostrophes' {
        ConvertTo-LabSamAccountName -GivenName 'Zoé' -Surname "D'Arcy" | Should -Be 'zdarcy'
    }
}

Describe 'New-LabPassword' {
    It 'respecte la longueur demandée' {
        (New-LabPassword -Length 24).Length | Should -Be 24
    }
    It 'contient les quatre classes de caractères' {
        1..50 | ForEach-Object {
            $p = New-LabPassword -Length 12
            $p | Should -MatchExactly '[a-z]'
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -Match '[0-9]'
            $p | Should -Match '[^a-zA-Z0-9]'
        }
    }
    It 'produit des valeurs différentes' {
        $set = 1..100 | ForEach-Object { New-LabPassword } | Sort-Object -Unique
        $set.Count | Should -Be 100
    }
    It 'refuse une longueur inférieure à 12' {
        { New-LabPassword -Length 8 } | Should -Throw
    }
}

Describe 'Import-LabCsv' {
    It 'signale les colonnes manquantes' {
        $tmp = Join-Path -Path $TestDrive -ChildPath 'x.csv'
        'A,B' , '1,2' | Set-Content -Path $tmp
        { Import-LabCsv -Path $tmp -RequiredColumns 'A', 'C' } | Should -Throw '*C*'
    }
}

Describe 'Export-LabHtmlReport' {
    It 'écrit index.html et un CSV par section nommée' {
        $dir = Join-Path -Path $TestDrive -ChildPath 'report'
        $index = Export-LabHtmlReport -Directory $dir -Title 'Test <script>' -Sections @(
            @{ Title = 'Section'; CsvName = 'data'; Data = @([pscustomobject]@{ A = 1 }) }
            @{ Title = 'Vide'; Data = @() }
        )
        $index | Should -Exist
        Join-Path -Path $dir -ChildPath 'data.csv' | Should -Exist
        Get-Content -Path $index -Raw | Should -Not -Match '<script>'
    }
}
