# 05 — GPO de sécurité

```powershell
# Sur DC01
.\scripts\ad\08-Configure-SecurityGPOs.ps1 -WhatIf
.\scripts\ad\08-Configure-SecurityGPOs.ps1
# Sur chaque machine jointe (redémarrer si des paramètres ordinateur ont changé)
gpupdate /force
.\scripts\ad\11-Test-MemberHardening.ps1
```

## Comment le script écrit les GPO

`Set-GPRegistryValue` ne couvre que les **modèles d'administration** (fichier `Registry.pol`). Les **options de sécurité**, la **stratégie d'audit** et l'**appartenance aux groupes locaux** se trouvent dans `GptTmpl.inf`, et les **lecteurs mappés** dans `Drives.xml`. Le module `LabGpo` écrit ces fichiers dans SYSVOL. Il effectue aussi les deux opérations que la console GPMC fait d'habitude en coulisses :

1. il déclare l'**extension côté client** dans `gPCMachineExtensionNames` / `gPCUserExtensionNames` ; sans elle, le client ignore le fichier ;
2. il incrémente la **version** de la GPO (16 bits utilisateur / 16 bits ordinateur) dans AD et dans `GPT.INI` ; sans cela, le client garde sa copie en cache.

Les fonctions pures du module (`Merge-LabGpoExtension`, `New-LabSecurityTemplate`, `New-LabDrivesXml`) sont couvertes par les tests Pester.

## Paramètres et attaques neutralisées

### GPO-SEC-Ordinateurs-Baseline (OU Ordinateurs)

| Paramètre | Valeur | Ce que ça empêche |
|---|---|---|
| `LmCompatibilityLevel` | 5 — NTLMv2 uniquement, LM/NTLMv1 refusés | Craquage instantané des réponses NTLMv1 capturées (downgrade) |
| `NoLMHash` | 1 | Stockage du hash LM, cassable en quelques secondes |
| Signature SMB serveur et client | Obligatoire | **Relais NTLM** vers SMB (ntlmrelayx) depuis une authentification capturée |
| `SMB1` | 0 | Exploitation de SMBv1 (EternalBlue / MS17-010) |
| `WDigest\UseLogonCredential` | 0 | Mots de passe en clair dans LSASS (mimikatz `sekurlsa::wdigest`) |
| `Lsa\RunAsPPL` | 1 | Lecture de la mémoire LSASS par un processus non protégé |
| `RestrictAnonymous` / `RestrictAnonymousSAM` | 1 | Énumération anonyme des comptes et partages (null session) |
| Journalisation des blocs de script + transcription PowerShell | Activées | Exécution PowerShell offensive sans trace (événement 4104, transcriptions dans `C:\ProgramData\PSTranscripts`) |
| Audit ouvertures de session, gestion des comptes, changements de stratégie | Succès + échecs | Attaques par force brute ou pulvérisation de mots de passe, création de comptes non détectées (4624/4625/4720/4728…) |
| Pare-feu (domaine, privé, public) | Actif, entrant bloqué par défaut | Mouvements latéraux vers des services exposés par erreur |
| Compte Invité | Désactivé | Accès anonyme déguisé |
| Dernier utilisateur masqué, verrouillage après 15 min, bannière | Activés | Collecte d'identifiants à l'écran, sessions laissées ouvertes |

### GPO-SEC-Postes-Durcissement (OU Ordinateurs/Postes)

| Paramètre | Valeur | Ce que ça empêche |
|---|---|---|
| `EnableMulticast` (LLMNR) | 0 | **Empoisonnement LLMNR** (Responder) : capture de hash NetNTLMv2 sur une faute de frappe dans un chemin UNC |
| `NoDriveTypeAutoRun` / `NoAutorun` | 255 / 1 | Exécution automatique depuis un support amovible |
| `RemovableStorageDevices\Deny_All` | 1 | Exfiltration et introduction de charges par clé USB |
| `Windows Defender\PUAProtection` | 1 | Installation d'applications potentiellement indésirables |
| `GG-Admins-Postes` → Administrateurs locaux | Forme « Membre de » | Utilisation des admins du domaine sur les postes, où leurs identifiants seraient exposés |

L'appartenance au groupe local utilise la forme **« Membre de »** (`*SID__Memberof`) et non la forme « Membres » des groupes restreints. Le groupe est ajouté sans vider les Administrateurs locaux, ce qui préserve le compte administrateur local géré par LAPS.

> NetBIOS sur TCP/IP (NBT-NS), également exploité par Responder, n'a pas de paramètre de GPO natif : il se désactive par carte réseau ou par l'option DHCP Microsoft 001. Le lab ne le fait pas encore ; c'est la première évolution listée dans [09](09-evolutions.md).

### GPO-SEC-LAPS (OU Ordinateurs)

Windows LAPS, intégré à Windows depuis avril 2023 :

- extension du schéma (`Update-LapsADSchema`) et droit d'écriture des ordinateurs sur leur propre attribut (`Set-LapsADComputerSelfPermission`) ;
- mot de passe de 16 caractères, complexité maximale, rotation tous les 30 jours ;
- **chiffré dans AD**, déchiffrable par les seuls admins du domaine ;
- après utilisation : réinitialisation et déconnexion au bout de 8 h.

Sans LAPS, toutes les machines clonées depuis le même modèle partagent le même mot de passe administrateur local : un seul hash suffit pour se déplacer sur tout le parc par **pass-the-hash**.

```powershell
# Sur DC01
Get-LapsADPassword -Identity CLT01 -AsPlainText
# Sur un client
Get-LapsDiagnostics -OutputFolder C:\Temp\Laps
```

### GPO utilisateur

| GPO | Paramètre |
|---|---|
| GPO-USR-Verrouillage-Ecran | Écran de veille sécurisé par mot de passe après 600 s (`HKCU\Software\Policies\...\Control Panel\Desktop`) |
| GPO-USR-Lecteurs-Reseau | Préférences : P: `\\SRV01\Commun` pour tous ; K: `\\SRV01\Comptabilite` ciblé sur GG-Comptabilite **ou** GG-Direction |

## Vérification

`11-Test-MemberHardening.ps1` lit **l'état effectif** de la machine (registre, configuration SMB, pare-feu, `auditpol`, membres des Administrateurs locaux), pas le contenu de la GPO. Il affiche un tableau CONFORME / ECART et peut l'exporter en CSV.

```powershell
.\scripts\ad\11-Test-MemberHardening.ps1 -ExportPath C:\Temp\hardening-$env:COMPUTERNAME.csv
gpresult /h C:\Temp\gpresult.html
```

> 📸 `05-gpmc-links.png` : GPMC, arborescence de l'OU HADRIEN-LAB avec les GPO liées.
> 📸 `05-gpresult.png` : `gpresult /r /scope computer` sur CLT01 listant les GPO-SEC-* appliquées.
> 📸 `05-hardening-check.png` : sortie de `11-Test-MemberHardening.ps1` (tous les contrôles CONFORME).
> 📸 `05-laps.png` : onglet LAPS de l'ordinateur CLT01 dans « Utilisateurs et ordinateurs AD ».

## Test offensif (facultatif)

Depuis une VM Kali sur le même commutateur, démontre la différence avant et après la GPO :

```bash
# Avant : Responder capture un hash NetNTLMv2 quand un utilisateur tape \\fichiers-typo sur CLT01
sudo responder -I eth0
# Après : plus aucune requête LLMNR n'est émise par CLT01 ; la signature SMB fait échouer ntlmrelayx
netexec smb 192.168.50.0/24 --gen-relay-list relay.txt   # liste vide : signature exigée partout
```

Ces tests ne s'exécutent que dans le lab isolé.
