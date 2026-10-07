# Captures d'écran à réaliser

Les captures doivent provenir **de ton propre lab** : elles prouvent que l'environnement existe et fonctionne. Enregistre chaque fichier sous le nom indiqué, dans ce dossier, au format PNG, en masquant les identifiants de tenant et les adresses e-mail réelles si tu publies le dépôt.

Coche chaque ligne au fur et à mesure (`[x]`). Une fois les captures prises, tu peux les intégrer dans les documents avec `![légende](screenshots/<fichier>.png)` à l'emplacement des repères 📸.

## Active Directory

- [ ] `02-dns-zones.png` — Console DNS : zone directe, zone inverse, `_msdcs` *(après script 03)*
- [ ] `02-dhcp-scope.png` — Console DHCP : étendue active, options, baux *(après script 04 et démarrage des clients)*
- [ ] `03-ou-tree.png` — ADUC : arborescence HADRIEN-LAB dépliée *(script 05)*
- [ ] `03-fgpp.png` — ADAC : Password Settings Container > PSO-Comptes-Admin *(script 05)*
- [ ] `03-users-groups.png` — Propriétés de GG-Comptabilite : Membres / Membre de *(script 06)*
- [ ] `04-computers.png` — ADUC : SRV01, CLT01, CLT02 dans leurs OU *(script 07)*
- [ ] `04-share-ntfs.png` — Sécurité avancée de `D:\Partages\Comptabilite` *(script 09)*
- [ ] `04-drives-user.png` — Explorateur de CLT01 : lecteurs P: et K: *(scripts 08 + 09)*
- [ ] `05-gpmc-links.png` — GPMC : GPO liées sous HADRIEN-LAB *(script 08)*
- [ ] `05-gpresult.png` — `gpresult /r /scope computer` sur CLT01 *(script 08)*
- [ ] `05-hardening-check.png` — Sortie de `11-Test-MemberHardening.ps1`
- [ ] `05-laps.png` — Onglet LAPS de CLT01 *(script 08)*
- [ ] `06-ad-report.png` — Rapport HTML `10-Export-ADReport.ps1`
- [ ] `06-account-risk.png` — `Get-LabAccountRisk` avant/après correction

## Microsoft 365

- [ ] `07-entra-users.png` — Entra : utilisateurs du lab *(script 21)*
- [ ] `07-group-licensing.png` — SG-M365-Licences > Licences *(script 21)*
- [ ] `07-dynamic-group.png` — Règle d'appartenance de SG-Dyn-IT *(script 21)*
- [ ] `07-exo-shared.png` — EAC : délégation de support@ *(script 22)*
- [ ] `07-spo-sites.png` — Centre d'administration SharePoint : sites actifs *(script 23)*
- [ ] `07-spo-sharing.png` — SharePoint : stratégie de partage *(script 23)*
- [ ] `07-ca-policies.png` — Liste des stratégies d'accès conditionnel *(script 24)*
- [ ] `07-ca-report-only.png` — Journal de connexion, onglet Rapport uniquement *(script 24)*
- [ ] `07-mfa-prompt.png` — Invite Authenticator avec correspondance de nombre
- [ ] `07-mfa-registration.png` — Détails de l'inscription MFA des utilisateurs

## Intune

- [ ] `08-oobe-work.png` — OOBE : configuration pour un usage professionnel
- [ ] `08-access-work.png` — Paramètres > Accès Professionnel ou Scolaire
- [ ] `08-dsregcmd.png` — `dsregcmd /status` *(script 26)*
- [ ] `08-mdm-diag.png` — MDMDiagReport.html *(script 26)*
- [ ] `08-intune-device.png` — Intune : fiche de CLT-CLOUD01
- [ ] `08-intune-compliance.png` — CLT-CLOUD01 : conformité WIN-Conformite-Base
- [ ] `08-intune-profiles.png` — CLT-CLOUD01 : profils de configuration réussis

## Conseils

- Outil Capture d'écran de Windows (`Win + Maj + S`), fenêtre seule, sans barre des tâches.
- Le mode sombre ou clair importe peu, mais garde le même mode sur toutes les captures.
- Le rapport HTML du script 27 (`-IncludeExchange`) peut remplacer plusieurs captures M365 si le temps manque.
