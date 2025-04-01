$Versions = @(
    '2.5.2'
    '2.5.1'

)
$PackageName = 'SBCL.SBCL'

foreach ($Version in $Versions) {
    $DownloadUrl = 'https://sourceforge.net/projects/sbcl/files/sbcl/{0}/sbcl-{0}-x86-64-windows-binary.msi/download' -f $Version
    komac update $PackageName -v $Version -u $DownloadUrl --submit
}