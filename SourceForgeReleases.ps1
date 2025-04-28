# Set the SourceForge "latest" URL for the project
# $latestUrl = 'https://sourceforge.net/projects/phppgadmin/files/latest/download'
$latestUrl = 'https://sourceforge.net/projects/winscp/files/latest/download'

# Send a web request and follow the redirect to get the real download URL
try {
    $response = Invoke-WebRequest -Uri $latestUrl -MaximumRedirection 0 -ErrorAction Stop
    $downloadUrl = $response.links.'data-release-url' | Select-Object -First 1
    if (-not $downloadUrl) {
        throw 'Download URL not found.'
    }
    # Remove everything after and including '?ts='
    $cleanUrl = $downloadUrl -replace '\?ts=.*', ''
    # Extract the version number (e.g., 6.5)
    if ($cleanUrl -match '/WinSCP/([^/]+)/') {
        $version = $matches[1]
    } else {
        $version = 'Unknown'
    }
    Write-Output "Latest version: $version"
    Write-Output "Clean download URL: $cleanUrl"
} catch {
    Write-Output 'Failed to retrieve the latest download URL.'
}