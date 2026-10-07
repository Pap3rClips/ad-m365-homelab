@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Les scripts sont interactifs : Write-Host est l'affichage voulu (couleurs de Write-LabLog)
        'PSAvoidUsingWriteHost'
        # Mots de passe générés aléatoirement par New-LabPassword, convertis juste avant New-ADUser
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
