# Discover the installed desktop application separately from its per-user data.
function Get-ClaudeDesktop {
    $names = @('Claude', 'Claude Desktop')
    $entries = @(Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $names })
    $packages = @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'Claude' -or $_.Publisher -match 'Anthropic'
    })
    $families = @($packages | ForEach-Object { $_.PackageFamilyName })
    foreach ($entry in $entries) {
        if ($entry.AppID -match '^([^!]+_[a-z0-9]{13})![^!]+$') { $families += $Matches[1] }
    }
    $launch = $null
    if ($entries.Count -eq 1) { $launch = 'shell:AppsFolder\' + $entries[0].AppID }
    if (!$launch -and $packages.Count -eq 1) {
        $manifest = Get-AppxPackageManifest -Package $packages[0].PackageFullName -ErrorAction SilentlyContinue
        $apps = @($manifest.Package.Applications.Application | Where-Object { $_.Executable -match '(^|[\\/])Claude\.exe$' })
        if ($apps.Count -eq 1) { $launch = 'shell:AppsFolder\' + $packages[0].PackageFamilyName + '!' + $apps[0].Id }
    }

    $roots = @()
    foreach ($local in @($env:LOCALAPPDATA, [Environment]::GetFolderPath('LocalApplicationData')) | Select-Object -Unique) {
        if (!$local) { continue }
        foreach ($family in @($families + 'Claude_pzs8sxrjxfjjc') | Select-Object -Unique) {
            if ($family -and $family -notmatch '[\\/]') {
                $roots += Join-Path $local "Packages\$family\LocalCache\Roaming\Claude"
            }
        }
    }
    foreach ($roaming in @($env:APPDATA, [Environment]::GetFolderPath('ApplicationData')) | Select-Object -Unique) {
        if ($roaming) { $roots += Join-Path $roaming 'Claude' }
    }
    $ready = @($roots | Select-Object -Unique | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_ 'config.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_ 'Local State') -PathType Leaf)
    })
    $root = $null
    if ($ready.Count -eq 1) {
        $root = $ready[0]
        $status = 'Claude Desktop data found.'
    } elseif ($ready.Count -gt 1) {
        $status = 'Multiple Claude Desktop data folders found. Profile switching is paused to avoid changing the wrong account.'
    } elseif ($launch -or $packages.Count -gt 0) {
        $status = 'Claude Desktop detected. Open Claude Desktop, sign in, then click Refresh. If this persists, the data layout may be unsupported.'
    } else {
        $status = 'Claude Desktop was not detected for this Windows user. Install or open the Windows desktop app, sign in, then click Refresh.'
    }
    [pscustomobject]@{ Root = $root; Launch = $launch; Status = $status }
}

function Start-DetectedClaude($Desktop) {
    if (!$Desktop.Launch) { throw 'No unambiguous Claude Desktop launcher was found. Open Claude Desktop from Windows Start.' }
    Start-Process $Desktop.Launch -ErrorAction Stop
}
