# 09 — Évolutions possibles

Pistes classées de la plus simple à la plus ambitieuse. Chacune s'appuie sur ce qui est déjà en place.

| Évolution | Intérêt | Point de départ |
|---|---|---|
| Désactiver NetBIOS sur TCP/IP | Ferme NBT-NS, second canal exploité par Responder après LLMNR | Option DHCP Microsoft 001 = 2 sur l'étendue, ou script de démarrage par GPO |
| Modèle d'administration en tiers (Tier 0/1/2) | Empêche les admins du domaine d'ouvrir une session sur les postes, où leurs identifiants seraient volés | GPO « Interdire l'ouverture de session » pour les comptes Tier 0 sur l'OU Postes ; OU `Comptes-Admin/Tier0`, `Tier1` |
| gMSA pour les comptes de service | Mot de passe de 240 caractères à rotation automatique : le Kerberoasting devient inutile | `Add-KdsRootKey`, `New-ADServiceAccount`, OU `Comptes-Service` déjà créée |
| Audit avancé + transfert d'événements (WEF) | Centraliser 4624/4625/4688/4104 | Collecteur sur SRV01, ou agent Wazuh déjà utilisé dans le homelab |
| Audit externe de l'annuaire | Mesure objective avant/après durcissement | PingCastle, BloodHound Community Edition, Purple Knight : comparer le score avant et après le script 08 |
| Synchronisation hybride Entra Cloud Sync | Un seul compte AD synchronisé vers le tenant ; jonction hybride des postes CLT01/CLT02 | Ajouter un suffixe UPN routable, installer l'agent Cloud Sync sur SRV01, filtrer sur l'OU `Utilisateurs` |
| Windows Autopilot | Déploiement zéro contact : le poste sort du carton déjà configuré | `26-Test-IntuneEnrollment.ps1 -CollectAutopilotHash`, import dans Intune, profil de déploiement |
| Applications Intune | Installer Microsoft 365 Apps, Company Portal, 7-Zip (Win32) | Intune > Applications > Windows |
| Accès conditionnel basé sur la conformité | N'autoriser Exchange/SharePoint que depuis un appareil conforme | Stratégie CA004 « Exiger un appareil conforme », d'abord en rapport uniquement sur SG-Dyn-IT |
| Microsoft Defender for Endpoint | EDR sur CLT-CLOUD01, intégration au niveau de risque de la conformité Intune | Connecteur Defender ↔ Intune, profil d'intégration EDR |
| AD CS durci | Autorité de certification interne (certificats Wi-Fi, LDAPS) sans les failles ESC1–ESC8 | Rôle AD CS sur SRV01, audit avec Certipy |
