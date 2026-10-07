@{
    # ------------------------------------------------------------------
    # Configuration centrale du lab — tous les scripts lisent ce fichier.
    # Adapter les valeurs à ton environnement avant la première exécution.
    # Aucun mot de passe ici : ils sont demandés à l'exécution.
    # ------------------------------------------------------------------

    Domain = @{
        FQDN         = 'corp.hadrien.lab'
        NetBIOS      = 'CORP'
        # Racine des OU métier : OU=HADRIEN-LAB,DC=corp,DC=hadrien,DC=lab
        RootOU       = 'HADRIEN-LAB'
        ForestMode   = 'WinThreshold'   # niveau fonctionnel 2016 (requis pour le chiffrement LAPS)
        DomainMode   = 'WinThreshold'
    }

    Network = @{
        InterfaceAlias = 'Ethernet'
        NetworkId      = '192.168.50.0'
        PrefixLength   = 24
        Gateway        = '192.168.50.1'
        DnsForwarders  = @('1.1.1.1', '9.9.9.9')
    }

    DomainController = @{
        Name      = 'DC01'
        IPAddress = '192.168.50.10'
    }

    Dhcp = @{
        ScopeName      = 'LAN-Clients'
        StartRange     = '192.168.50.100'
        EndRange       = '192.168.50.200'
        SubnetMask     = '255.255.255.0'
        LeaseDuration  = '8.00:00:00'
        # Plage exclue réservée aux serveurs et équipements à IP fixe
        Exclusions     = @(
            @{ Start = '192.168.50.100'; End = '192.168.50.109' }
        )
        # Réservation pour le poste d'administration (remplacer la MAC par celle de ta VM)
        Reservations   = @(
            @{ Name = 'CLT02'; IPAddress = '192.168.50.150'; MacAddress = '00-15-5D-00-00-02' }
        )
    }

    # Les trois machines jointes au domaine
    Members = @(
        @{ Name = 'SRV01'; Role = 'Serveur de fichiers';   OU = 'Serveurs';  OS = 'Windows Server 2022'; IPAddress = '192.168.50.20' }
        @{ Name = 'CLT01'; Role = 'Poste utilisateur';     OU = 'Postes';    OS = 'Windows 11 Pro' }
        @{ Name = 'CLT02'; Role = 'Poste administrateur';  OU = 'Postes';    OS = 'Windows 11 Pro' }
    )

    # Arborescence des OU (créées sous RootOU, dans l'ordre)
    OrganizationalUnits = @(
        'Utilisateurs'
        'Utilisateurs/Direction'
        'Utilisateurs/IT'
        'Utilisateurs/Comptabilite'
        'Utilisateurs/Commercial'
        'Ordinateurs'
        'Ordinateurs/Postes'
        'Ordinateurs/Serveurs'
        'Groupes'
        'Groupes/Securite'
        'Groupes/Ressources'
        'Comptes-Admin'
        'Comptes-Service'
        'Desactives'
    )

    # Groupes globaux (rôles) et domaine local (ressources) — modèle AGDLP
    Groups = @(
        @{ Name = 'GG-Direction';         Scope = 'Global';      OU = 'Groupes/Securite';   Description = 'Membres de la direction' }
        @{ Name = 'GG-IT';                Scope = 'Global';      OU = 'Groupes/Securite';   Description = 'Équipe informatique' }
        @{ Name = 'GG-Comptabilite';      Scope = 'Global';      OU = 'Groupes/Securite';   Description = 'Service comptabilité' }
        @{ Name = 'GG-Commercial';        Scope = 'Global';      OU = 'Groupes/Securite';   Description = 'Service commercial' }
        @{ Name = 'GG-Admins-Postes';     Scope = 'Global';      OU = 'Groupes/Securite';   Description = 'Administrateurs locaux des postes (comptes adm-*)' }
        @{ Name = 'DL-Partage-Commun-RW'; Scope = 'DomainLocal'; OU = 'Groupes/Ressources'; Description = 'Lecture/écriture sur \\SRV01\Commun' }
        @{ Name = 'DL-Partage-Compta-RW'; Scope = 'DomainLocal'; OU = 'Groupes/Ressources'; Description = 'Lecture/écriture sur \\SRV01\Comptabilite' }
        @{ Name = 'DL-Partage-Compta-RO'; Scope = 'DomainLocal'; OU = 'Groupes/Ressources'; Description = 'Lecture seule sur \\SRV01\Comptabilite' }
    )

    # Imbrication AGDLP : groupe global -> groupe domaine local
    GroupNesting = @(
        @{ Member = 'GG-Direction';    Group = 'DL-Partage-Commun-RW' }
        @{ Member = 'GG-IT';           Group = 'DL-Partage-Commun-RW' }
        @{ Member = 'GG-Comptabilite'; Group = 'DL-Partage-Commun-RW' }
        @{ Member = 'GG-Commercial';   Group = 'DL-Partage-Commun-RW' }
        @{ Member = 'GG-Comptabilite'; Group = 'DL-Partage-Compta-RW' }
        @{ Member = 'GG-Direction';    Group = 'DL-Partage-Compta-RO' }
    )

    # Partages hébergés sur SRV01 ; lecteurs mappés par GPO (préférences) selon le groupe
    FileServer = 'SRV01'
    FileShares = @(
        @{ Name = 'Commun';       Path = 'D:\Partages\Commun';       Modify = 'DL-Partage-Commun-RW'; Read = $null
           DriveLetter = 'P'; DriveGroups = @() }                                   # pour tous les utilisateurs
        @{ Name = 'Comptabilite'; Path = 'D:\Partages\Comptabilite'; Modify = 'DL-Partage-Compta-RW'; Read = 'DL-Partage-Compta-RO'
           DriveLetter = 'K'; DriveGroups = @('GG-Comptabilite', 'GG-Direction') }  # ciblage par groupe
    )

    # Bannière affichée avant l'ouverture de session
    LogonBanner = @{
        Caption = 'Système d''information Hadrien Lab'
        Text    = 'Accès réservé aux personnes autorisées. Les connexions sont journalisées.'
    }

    PasswordPolicy = @{
        MinPasswordLength        = 12
        PasswordHistoryCount     = 24
        MaxPasswordAge           = '180.00:00:00'
        MinPasswordAge           = '1.00:00:00'
        LockoutThreshold         = 5
        LockoutDuration          = '00:15:00'
        LockoutObservationWindow = '00:15:00'
        # Stratégie affinée (FGPP) plus stricte pour les comptes à privilèges
        AdminFGPP = @{
            Name              = 'PSO-Comptes-Admin'
            Precedence        = 10
            MinPasswordLength = 16
            MaxPasswordAge    = '90.00:00:00'
            AppliesTo         = 'GG-Admins-Postes'
        }
    }

    Laps = @{
        PasswordLength    = 16
        PasswordAgeDays   = 30
        EncryptPasswords  = $true
    }

    # ------------------------------------------------------------------
    # Hôte Hyper-V (script scripts/host/00-New-HyperVLab.ps1)
    # Sous Proxmox, reproduire ces VM à la main (OVMF + TPM 2.0 + Secure Boot)
    # ------------------------------------------------------------------
    HyperV = @{
        SwitchName = 'LAB-HADRIEN'
        NatName    = 'LAB-HADRIEN-NAT'
        VMPath     = 'D:\Hyper-V\HadrienLab'
        Iso = @{
            Server = 'D:\ISO\WindowsServer2022_EVAL.iso'
            Client = 'D:\ISO\Windows11_Enterprise_EVAL.iso'
        }
        VMs = @(
            @{ Name = 'DC01';        Iso = 'Server'; MemoryGB = 4; Cpu = 2; DiskGB = 60 }
            @{ Name = 'SRV01';       Iso = 'Server'; MemoryGB = 4; Cpu = 2; DiskGB = 60; DataDiskGB = 40 }
            @{ Name = 'CLT01';       Iso = 'Client'; MemoryGB = 4; Cpu = 2; DiskGB = 64 }
            @{ Name = 'CLT02';       Iso = 'Client'; MemoryGB = 4; Cpu = 2; DiskGB = 64; MacAddress = '00155D000002' }
            # Poste « cloud only » : joint à Entra ID et inscrit dans Intune, hors domaine AD
            @{ Name = 'CLT-CLOUD01'; Iso = 'Client'; MemoryGB = 4; Cpu = 2; DiskGB = 64 }
        )
    }

    # ------------------------------------------------------------------
    # Microsoft 365
    # ------------------------------------------------------------------
    M365 = @{
        TenantDomain     = 'hadrienlab.onmicrosoft.com'   # domaine initial du tenant
        SharePointPrefix = 'hadrienlab'                    # https://<prefix>-admin.sharepoint.com
        UsageLocation    = 'FR'
        # SKU attribué par licence de groupe (voir Get-MgSubscribedSku) :
        # DEVELOPERPACK_E5 (tenant développeur) ou SPB (Business Premium)
        LicenseSkuPartNumber = 'DEVELOPERPACK_E5'
        LicensedGroup        = 'SG-M365-Licences'

        BreakGlassUpn = 'bg-admin'                         # suffixé par TenantDomain

        DynamicGroups = @(
            @{ Name = 'SG-Dyn-IT';            Rule = '(user.department -eq "IT")' }
            @{ Name = 'SG-Dyn-Comptabilite';  Rule = '(user.department -eq "Comptabilite")' }
            @{ Name = 'SG-Dyn-Postes-Windows'; Rule = '(device.deviceOSType -eq "Windows")'; Devices = $true }
        )

        SharedMailboxes = @(
            @{ Name = 'Support';   Alias = 'support';   Members = @('IT') }
            @{ Name = 'Factures';  Alias = 'factures';  Members = @('Comptabilite') }
        )

        DistributionLists = @(
            @{ Name = 'Tous';      Alias = 'tous' }
        )

        SharePointSites = @(
            @{ Title = 'Intranet';     Url = 'intranet';     Template = 'SITEPAGEPUBLISHING#0'; Description = 'Site de communication de l''entreprise' }
        )
        # Groupes Microsoft 365 (créent chacun un site d'équipe SharePoint)
        TeamSites = @(
            @{ Name = 'Equipe-IT';           Alias = 'equipe-it';           Department = 'IT' }
            @{ Name = 'Equipe-Comptabilite'; Alias = 'equipe-comptabilite'; Department = 'Comptabilite' }
        )

        Intune = @{
            CompliancePolicyName = 'WIN-Conformite-Base'
            ConfigProfileName    = 'WIN-Restrictions-Base'
            MinOsVersion         = '10.0.22631'          # Windows 11 23H2
            TargetGroup          = 'SG-Dyn-Postes-Windows'
        }
    }
}
