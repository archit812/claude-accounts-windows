$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../ClaudeAccounts/claude-discovery.ps1')
function Get-StartApps { [pscustomobject]@{ Name='Claude'; AppID='Example.Claude_123456789abcd!Desktop' } }
function Get-AppxPackage { }
$tempRoot = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
$env:LOCALAPPDATA = Join-Path $tempRoot 'Local'
$env:APPDATA = Join-Path $tempRoot 'Roaming'
function Get-TestDesktop { Get-ClaudeDesktop -LocalFolders $env:LOCALAPPDATA -RoamingFolders $env:APPDATA }
try {
    $result = Get-TestDesktop
    if ($result.Root -or $result.Status -notlike 'Claude Desktop detected*') { throw 'Expected installed but uninitialized' }
    $root = Join-Path $env:LOCALAPPDATA 'Packages\Example.Claude_123456789abcd\LocalCache\Roaming\Claude'
    [void](New-Item $root -ItemType Directory -Force)
    [void](New-Item (Join-Path $root 'config.json') -ItemType File)
    if ((Get-TestDesktop).Root) { throw 'Partial folder accepted' }
    [void](New-Item (Join-Path $root 'Local State') -ItemType File)
    $result = Get-TestDesktop
    if ($result.Root -ne $root -or $result.Launch -ne 'shell:AppsFolder\Example.Claude_123456789abcd!Desktop') { throw 'Registered install discovery failed' }
    $other = Join-Path $env:APPDATA 'Claude'
    [void](New-Item $other -ItemType Directory -Force)
    Copy-Item "$root\*" $other -Force
    if ((Get-TestDesktop).Status -notlike 'Multiple*') { throw 'Ambiguous folder accepted' }
    Remove-Item $root -Recurse -Force
    if ((Get-TestDesktop).Root -ne $other) { throw 'Standard roaming folder missed' }
    Remove-Item $other -Recurse -Force
    function Get-StartApps { }
    if ((Get-TestDesktop).Status -notlike 'Claude Desktop was not detected*') { throw 'Missing install not reported' }
    function Get-AppxPackage {
        [pscustomobject]@{ Name='Claude'; PackageFamilyName='Claude_123456789abcd'; PackageFullName='Claude_test' }
    }
    function Get-AppxPackageManifest {
        [xml]'<Package><Applications><Application Id="Desktop" Executable="app/Claude.exe" /></Applications></Package>'
    }
    if ((Get-TestDesktop).Launch -ne 'shell:AppsFolder\Claude_123456789abcd!Desktop') { throw 'Manifest launch target missed' }
    foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot '../ClaudeAccounts/*.ps1')) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors)
        if ($errors) { throw ($errors | Out-String) }
    }
} finally {
    if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
}
