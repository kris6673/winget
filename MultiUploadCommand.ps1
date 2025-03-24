$Versions = @(
    '0.6.00'
    '0.6.01'
)
$PackageName = 'LightBurnSoftware.LightBurn'

foreach ($Version in $Versions) {
    
    $DownloadUrl = 'https://release.lightburnsoftware.com/LightBurn/Release/LightBurn-v{0}/LightBurn-v{0}.exe' -f $Version
    komac update $PackageName -v $Version -u $DownloadUrl --submit --dry-run
}