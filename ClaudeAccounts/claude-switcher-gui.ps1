<#
.SYNOPSIS
    Windows GUI for the Claude account switcher, session mover, and limit watcher.

.DESCRIPTION
    Wraps claude-profile.ps1, claude-sessions.ps1 and claude-autoswitch.ps1 so
    none of them need to be driven from a command line.

    Reads state directly from disk (config.json, the profile store, the session
    index) and shells out to the three scripts only to perform actions, so the
    lists stay accurate even if something changes them outside this window.
#>

#requires -version 5
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'

# --- Locate the tools --------------------------------------------------------

$ScriptDir     = $PSScriptRoot
$ProfileScript = Join-Path $ScriptDir 'claude-profile.ps1'
$SessionScript = Join-Path $ScriptDir 'claude-sessions.ps1'


foreach ($s in @($ProfileScript, $SessionScript)) {
    if (-not (Test-Path $s)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Missing: $s`n`nKeep all four scripts in the same folder.",
            'Claude Switcher', 'OK', 'Error')
        return
    }
}

# --- State readers (mirror the scripts; never trust cached labels) -----------

function Get-ClaudePackageFamily {
    foreach ($n in @('Claude', '*Claude*')) {
        try {
            $p = @(Get-AppxPackage -Name $n -ErrorAction Stop)
            if ($p.Count -gt 0) { return $p[0].PackageFamilyName }
        } catch { }
    }
    return 'Claude_pzs8sxrjxfjjc'   # last-known default
}

function Get-ClaudeAumid {
    try {
        $a = @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -eq 'Claude' })
        if ($a.Count -gt 0) { return $a[0].AppID }
    } catch { }
    return ((Get-ClaudePackageFamily) + '!Claude')
}

function Resolve-AppRoot {
    $fam = Get-ClaudePackageFamily
    foreach ($c in @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA "Packages\$fam\LocalCache\Roaming\Claude"))) {
        if (Test-Path (Join-Path $c 'config.json')) { return $c }
    }
    return $null
}

$AppRoot      = Resolve-AppRoot
$Store        = Join-Path $env:USERPROFILE '.claude-profiles'
$SessionsRoot = if ($AppRoot) { Join-Path $AppRoot 'claude-code-sessions' } else { $null }
$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$LogFile      = Join-Path $Store 'autoswitch.log'
$StateFile    = Join-Path $Store 'autoswitch-cooldowns.json'

function Read-Trimmed {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $t = [System.IO.File]::ReadAllText($Path)
        return $t.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
    } catch { return $null }
}

function Get-LiveUuid {
    if (-not $AppRoot) { return $null }
    try { return (Get-Content (Join-Path $AppRoot 'config.json') -Raw | ConvertFrom-Json).lastKnownAccountUuid }
    catch { return $null }
}

function Get-Profiles {
    $out = @()
    if (-not (Test-Path $Store)) { return $out }
    $items = @('Local State','Network','Local Storage','Session Storage','config.json','claude.json')
    foreach ($p in Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue) {
        if ($p.Name -like '.*') { continue }
        $uuid = $null
        $cfg = Join-Path $p.FullName 'config.json'
        if (Test-Path $cfg) {
            try { $uuid = (Get-Content $cfg -Raw | ConvertFrom-Json).lastKnownAccountUuid } catch { }
        }
        if (-not $uuid) { $uuid = Read-Trimmed (Join-Path $p.FullName 'account-uuid.txt') }
        $complete = $true
        foreach ($i in $items) { if (-not (Test-Path (Join-Path $p.FullName $i))) { $complete = $false } }
        $label = Read-Trimmed (Join-Path $p.FullName 'label.txt')
        if (-not $label) { $label = $p.Name }
        $out += [pscustomobject]@{ Name = $p.Name; Label = $label; Uuid = $uuid; Complete = $complete }
    }
    return $out
}

function Get-SessionsFor {
    param([string]$Uuid)
    $out = @()
    if (-not $SessionsRoot -or -not $Uuid) { return $out }
    $dir = Join-Path $SessionsRoot $Uuid
    if (-not (Test-Path $dir)) { return $out }
    foreach ($org in Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue) {
        foreach ($f in Get-ChildItem $org.FullName -Filter 'local_*.json' -ErrorAction SilentlyContinue) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            $out += [pscustomobject]@{
                SessionId = $j.sessionId
                CliId     = $j.cliSessionId
                Title     = $(if ($j.title) { $j.title } else { '<untitled>' })
                Cwd       = $j.cwd
                LastAt    = $j.lastActivityAt
            }
        }
    }
    return $out | Sort-Object { [int64]$_.LastAt } -Descending
}

# Authoritative: the watcher holds this mutex for its whole life. Process-list
# scraping is only used to report the PID, and is allowed to fail without
# turning a running watcher into a reported "stopped".
function Format-Epoch {
    param($Milliseconds)
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Milliseconds).LocalDateTime.ToString('g') }
    catch { return '' }
}

function Get-ShortUuid {
    param([string]$U)
    if (-not $U) { return '<unknown>' }
    if ($U.Length -le 8) { return $U }
    return $U.Substring(0,8) + '...'
}

# --- Form scaffolding --------------------------------------------------------

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Claude Account Switcher'
$form.Size            = New-Object System.Drawing.Size(940, 700)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object System.Drawing.Size(820, 600)

$header               = New-Object System.Windows.Forms.Label
$header.Location      = New-Object System.Drawing.Point(14, 12)
$header.Size          = New-Object System.Drawing.Size(760, 22)
$header.Font          = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($header)

$btnRefresh           = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = 'Refresh'
$btnRefresh.Location  = New-Object System.Drawing.Point(800, 8)
$btnRefresh.Size      = New-Object System.Drawing.Size(110, 26)
$btnRefresh.Anchor    = 'Top,Right'
$form.Controls.Add($btnRefresh)

$tabs                 = New-Object System.Windows.Forms.TabControl
$tabs.Location        = New-Object System.Drawing.Point(12, 42)
$tabs.Size            = New-Object System.Drawing.Size(898, 400)
$tabs.Anchor          = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabs)

$outBox               = New-Object System.Windows.Forms.TextBox
$outBox.Location      = New-Object System.Drawing.Point(12, 452)
$outBox.Size          = New-Object System.Drawing.Size(898, 200)
$outBox.Multiline     = $true
$outBox.ScrollBars    = 'Vertical'
$outBox.ReadOnly      = $true
$outBox.Font          = New-Object System.Drawing.Font('Consolas', 9)
$outBox.Anchor        = 'Bottom,Left,Right'
$form.Controls.Add($outBox)

function Add-Output {
    param([string]$Text)
    if (-not $Text) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $outBox.AppendText("[$stamp] " + $Text.TrimEnd() + "`r`n")
    $outBox.SelectionStart = $outBox.TextLength
    $outBox.ScrollToCaret()
}

# $Arguments is splatted as an array, which binds POSITIONALLY -- a '-Switch'
# string in there arrives as a value and fails to bind. Named parameters and
# switches must go through $Named, which splats as a hashtable.
function Invoke-Tool {
    param([string]$Script, [string[]]$Arguments, [hashtable]$Named)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:Busy = $true          # keep the auto-refresh timer out of the way
    try {
        if ($null -eq $Named) { $Named = @{} }
        $res = & $Script @Arguments @Named *>&1 | Out-String
        Add-Output $res
    } catch {
        Add-Output ("ERROR: " + $_.Exception.Message)
    } finally {
        $script:Busy = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Show-Ask {
    param([string]$Prompt, [string]$Default = '')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Claude Switcher'; $dlg.Size = New-Object System.Drawing.Size(420, 150)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt; $lbl.Location = New-Object System.Drawing.Point(12, 15)
    $lbl.Size = New-Object System.Drawing.Size(390, 20); $dlg.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Default; $tb.Location = New-Object System.Drawing.Point(12, 40)
    $tb.Size = New-Object System.Drawing.Size(385, 24); $dlg.Controls.Add($tb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = New-Object System.Drawing.Point(225, 75)
    $ok.Size = New-Object System.Drawing.Size(80, 26); $ok.DialogResult = 'OK'; $dlg.Controls.Add($ok)

    $ca = New-Object System.Windows.Forms.Button
    $ca.Text = 'Cancel'; $ca.Location = New-Object System.Drawing.Point(315, 75)
    $ca.Size = New-Object System.Drawing.Size(80, 26); $ca.DialogResult = 'Cancel'; $dlg.Controls.Add($ca)

    $dlg.AcceptButton = $ok; $dlg.CancelButton = $ca
    if ($dlg.ShowDialog($form) -eq 'OK') { return $tb.Text.Trim() }
    return $null
}

# =============================== Tab: Profiles ===============================

$tabProfiles          = New-Object System.Windows.Forms.TabPage
$tabProfiles.Text     = 'Accounts'
$tabs.Controls.Add($tabProfiles)

$lvProfiles           = New-Object System.Windows.Forms.ListView
$lvProfiles.Location  = New-Object System.Drawing.Point(10, 12)
$lvProfiles.Size      = New-Object System.Drawing.Size(640, 330)
$lvProfiles.View      = 'Details'
$lvProfiles.FullRowSelect = $true
$lvProfiles.MultiSelect   = $false
$lvProfiles.GridLines     = $true
$lvProfiles.Anchor        = 'Top,Bottom,Left,Right'
[void]$lvProfiles.Columns.Add('', 28)
[void]$lvProfiles.Columns.Add('Profile', 110)
[void]$lvProfiles.Columns.Add('Account', 220)
[void]$lvProfiles.Columns.Add('UUID', 110)
[void]$lvProfiles.Columns.Add('State', 90)
$tabProfiles.Controls.Add($lvProfiles)

$lblProfHint          = New-Object System.Windows.Forms.Label
$lblProfHint.Location = New-Object System.Drawing.Point(662, 284)
$lblProfHint.Size     = New-Object System.Drawing.Size(214, 60)
$lblProfHint.Anchor   = 'Top,Right'
$lblProfHint.ForeColor = [System.Drawing.Color]::DimGray
$lblProfHint.Text     = "Double-click an account to switch to it.`r`n`r`nSwitching closes and reopens Claude."
$tabProfiles.Controls.Add($lblProfHint)

$profButtons = @(
    @{ Text = 'Switch to selected'; Y = 12  ; Name = 'switch' },
    @{ Text = 'Add account...';     Y = 48  ; Name = 'add'    },
    @{ Text = 'Save current as...'; Y = 84  ; Name = 'save'   },
    @{ Text = 'Rename...';          Y = 120 ; Name = 'rename' },
    @{ Text = 'Set label...';       Y = 156 ; Name = 'label'  },
    @{ Text = 'Delete...';          Y = 192 ; Name = 'delete' },
    @{ Text = 'Diagnostics';        Y = 238 ; Name = 'doctor' }
)
$profBtn = @{}
foreach ($b in $profButtons) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $b.Text
    $btn.Location = New-Object System.Drawing.Point(662, $b.Y)
    $btn.Size = New-Object System.Drawing.Size(214, 30)
    $btn.Anchor = 'Top,Right'
    $tabProfiles.Controls.Add($btn)
    if ($b.Name -in @('delete','rename')) { $btn.Visible = $false }
    $profBtn[$b.Name] = $btn
}

# =============================== Tab: Sessions ===============================

$tabSessions          = New-Object System.Windows.Forms.TabPage
$tabSessions.Text     = 'Sessions'
$tabs.Controls.Add($tabSessions)

$lblAcct              = New-Object System.Windows.Forms.Label
$lblAcct.Text         = 'Account:'
$lblAcct.Location     = New-Object System.Drawing.Point(10, 16)
$lblAcct.Size         = New-Object System.Drawing.Size(60, 20)
$tabSessions.Controls.Add($lblAcct)

$cbAccount            = New-Object System.Windows.Forms.ComboBox
$cbAccount.Location   = New-Object System.Drawing.Point(72, 12)
$cbAccount.Size       = New-Object System.Drawing.Size(300, 24)
$cbAccount.DropDownStyle = 'DropDownList'
$tabSessions.Controls.Add($cbAccount)

$lvSessions           = New-Object System.Windows.Forms.ListView
$lvSessions.Location  = New-Object System.Drawing.Point(10, 46)
$lvSessions.Size      = New-Object System.Drawing.Size(640, 296)
$lvSessions.View      = 'Details'
$lvSessions.FullRowSelect = $true
$lvSessions.MultiSelect   = $false
$lvSessions.GridLines     = $true
$lvSessions.Anchor        = 'Top,Bottom,Left,Right'
[void]$lvSessions.Columns.Add('Last active', 100)
[void]$lvSessions.Columns.Add('Title', 300)
[void]$lvSessions.Columns.Add('Transcript', 90)
[void]$lvSessions.Columns.Add('Session id', 140)
$tabSessions.Controls.Add($lvSessions)

$btnCopySession       = New-Object System.Windows.Forms.Button
$btnCopySession.Text  = 'Copy to other account'
$btnCopySession.Location = New-Object System.Drawing.Point(662, 46)
$btnCopySession.Size  = New-Object System.Drawing.Size(214, 30)
$btnCopySession.Anchor = 'Top,Right'
$tabSessions.Controls.Add($btnCopySession)

$lblSessHint          = New-Object System.Windows.Forms.Label
$lblSessHint.Location = New-Object System.Drawing.Point(662, 84)
$lblSessHint.Size     = New-Object System.Drawing.Size(214, 150)
$lblSessHint.Anchor   = 'Top,Right'
$lblSessHint.ForeColor = [System.Drawing.Color]::DimGray
$lblSessHint.Text     = "Transcripts are shared between accounts - copying only adds the session to the other account's list. The original stays put.`r`n`r`nRestart Claude for a copied session to appear."
$tabSessions.Controls.Add($lblSessHint)

# Use layout containers so action buttons stay on-screen at different DPI settings.
function Set-ActionLayout {
    param($Page, $List, $Actions, $Selector)
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Fill'
    $grid.Padding = New-Object System.Windows.Forms.Padding(8)
    $grid.ColumnCount = 1
    $grid.RowCount = 3
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    foreach ($style in @('AutoSize','Percent','AutoSize')) {
        $row = New-Object System.Windows.Forms.RowStyle
        $row.SizeType = $style
        if ($style -eq 'Percent') { $row.Height = 100 }
        [void]$grid.RowStyles.Add($row)
    }
    if ($Selector) {
        $Selector.Dock = 'Top'
        $grid.Controls.Add($Selector, 0, 0)
    }
    $List.Dock = 'Fill'
    $grid.Controls.Add($List, 0, 1)
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Fill'
    $bar.AutoSize = $true
    $bar.WrapContents = $true
    foreach ($action in $Actions) {
        $action.Anchor = 'Top,Left'
        $action.AutoSize = $true
        $action.Width = 105
        $bar.Controls.Add($action)
    }
    $grid.Controls.Add($bar, 0, 2)
    $Page.Controls.Add($grid)
    $grid.BringToFront()
}
$lblProfHint.Visible = $false
$lblAcct.Visible = $false
$lblSessHint.Visible = $false
Set-ActionLayout $tabProfiles $lvProfiles @($profBtn['save'], $profBtn['add'], $profBtn['switch'], $profBtn['label'], $profBtn['doctor']) $null
Set-ActionLayout $tabSessions $lvSessions @($btnCopySession) $cbAccount

function Update-All {
    $script:AppRoot = Resolve-AppRoot
    if ($AppRoot) { $script:SessionsRoot = Join-Path $AppRoot 'claude-code-sessions' }
    $live = Get-LiveUuid
    $script:Profiles = @(Get-Profiles)

    $liveProf = $null
    foreach ($p in $script:Profiles) { if ($p.Uuid -eq $live) { $liveProf = $p } }

    if ($liveProf) {
        $header.Text = "Signed in: $($liveProf.Label)   ($($liveProf.Name))"
    } elseif ($live) {
        $header.Text = "Signed in: $(Get-ShortUuid $live)   (no matching profile)"
    } else {
        $header.Text = 'Signed in: unknown - is the desktop app installed?'
    }

    $lvProfiles.Items.Clear()
    foreach ($p in $script:Profiles) {
        $mark = ''
        if ($p.Uuid -eq $live) { $mark = [char]0x25CF }
        $state = 'ok'
        if (-not $p.Complete) { $state = 'INCOMPLETE' }
        $it = New-Object System.Windows.Forms.ListViewItem($mark)
        [void]$it.SubItems.Add($p.Name)
        [void]$it.SubItems.Add($p.Label)
        [void]$it.SubItems.Add((Get-ShortUuid $p.Uuid))
        [void]$it.SubItems.Add($state)
        $it.Tag = $p
        if (-not $p.Complete) { $it.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif ($p.Uuid -eq $live) { $it.ForeColor = [System.Drawing.Color]::SeaGreen }
        [void]$lvProfiles.Items.Add($it)
    }

    # Sessions tab account list
    $sel = $cbAccount.SelectedIndex
    $cbAccount.Items.Clear()
    foreach ($p in $script:Profiles) { [void]$cbAccount.Items.Add("$($p.Name)  -  $($p.Label)") }
    if ($cbAccount.Items.Count -gt 0) {
        if ($sel -ge 0 -and $sel -lt $cbAccount.Items.Count) { $cbAccount.SelectedIndex = $sel }
        else { $cbAccount.SelectedIndex = 0 }
    }

    Update-Sessions
}

function Update-Sessions {
    $lvSessions.Items.Clear()
    if ($cbAccount.SelectedIndex -lt 0) { return }
    $p = $script:Profiles[$cbAccount.SelectedIndex]
    if (-not $p) { return }

    $tx = @{}
    if (Test-Path $ProjectsRoot) {
        foreach ($f in Get-ChildItem $ProjectsRoot -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
            $tx[$f.BaseName] = $true
        }
    }

    foreach ($s in Get-SessionsFor $p.Uuid) {
        $it = New-Object System.Windows.Forms.ListViewItem((Format-Epoch $s.LastAt))
        [void]$it.SubItems.Add($s.Title)
        $has = 'ok'
        if (-not $tx.ContainsKey([string]$s.CliId)) { $has = 'MISSING' }
        [void]$it.SubItems.Add($has)
        [void]$it.SubItems.Add($s.SessionId)
        $it.Tag = $s
        if ($has -eq 'MISSING') { $it.ForeColor = [System.Drawing.Color]::Firebrick }
        [void]$lvSessions.Items.Add($it)
    }
}

$btnRefresh.Add_Click({ Update-All })
$cbAccount.Add_SelectedIndexChanged({ Update-Sessions })

function Get-SelectedProfile {
    if ($lvProfiles.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select an account first.', 'Claude Switcher', 'OK', 'Information')
        return $null
    }
    return $lvProfiles.SelectedItems[0].Tag
}

function Invoke-SwitchToSelected {
    $p = Get-SelectedProfile
    if (-not $p) { return }
    if (-not $p.Complete) {
        [void][System.Windows.Forms.MessageBox]::Show("Profile '$($p.Name)' is incomplete and cannot be restored. Re-save it while signed into that account.", 'Claude Switcher', 'OK', 'Warning')
        return
    }
    if ($p.Uuid -eq (Get-LiveUuid)) {
        [void][System.Windows.Forms.MessageBox]::Show("Already signed in as $($p.Label).", 'Claude Switcher', 'OK', 'Information')
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Switch to '$($p.Name)' ($($p.Label))?`n`nThis closes Claude and reopens it.",
        'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $ProfileScript @('switch', $p.Name)
    Update-All
}

$profBtn['switch'].Add_Click({ Invoke-SwitchToSelected })
$lvProfiles.Add_DoubleClick({ Invoke-SwitchToSelected })

# Guided flow for signing in a second account and capturing it as a profile.
# The app has no multi-account support, so the only way to add one is to sign
# out, sign in as the other account, and save what that leaves behind.
$profBtn['add'].Add_Click({
    $name = Show-Ask 'Short profile name for the new account (e.g. work):'
    if (-not $name) { return }
    if ($name -like '.*') {
        [void][System.Windows.Forms.MessageBox]::Show('Profile names cannot start with a dot.', 'Claude Switcher', 'OK', 'Warning')
        return
    }
    foreach ($p in $script:Profiles) {
        if ($p.Name -eq $name) {
            [void][System.Windows.Forms.MessageBox]::Show("A profile named '$name' already exists.", 'Claude Switcher', 'OK', 'Warning')
            return
        }
    }

    $before = Get-LiveUuid
    Start-Process ('shell:AppsFolder\' + (Get-ClaudeAumid))

    $r = [System.Windows.Forms.MessageBox]::Show(
        ("Claude is opening.`n`n" +
         "1. Open the account menu (bottom left)`n" +
         "2. Choose Log out`n" +
         "3. Sign in as the account you want to add`n`n" +
         "Then click OK here. Cancel abandons this."),
        'Add an account', 'OKCancel', 'Information')
    if ($r -ne 'OK') { Add-Output 'Add account: cancelled.'; return }

    $after = Get-LiveUuid
    if ($after -and $before -and $after -eq $before) {
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            ("Claude Code still reports the same account.`n`n" +
             "Signing out only on the Chat side does not move Claude Code. " +
             "Save anyway?`n`n(The save will refuse if the account really has not changed.)"),
            'Add an account', 'YesNo', 'Warning')
        if ($r2 -ne 'Yes') { Add-Output 'Add account: account unchanged, nothing saved.'; return }
    }

    Invoke-Tool $ProfileScript @('save', $name)
    Update-All

    $exists = $false
    foreach ($p in Get-Profiles) { if ($p.Name -eq $name) { $exists = $true } }
    if ($exists) {
        $lbl = Show-Ask "Saved. Display name for this account:" ''
        if ($lbl) { Invoke-Tool $ProfileScript @('label', $name, $lbl) }
        Update-All
    }
})

$profBtn['save'].Add_Click({
    $n = Show-Ask 'Save the currently signed-in account as which profile name?'
    if (-not $n) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Save current session as '$n'?`n`nThis closes Claude.", 'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $ProfileScript @('save', $n)
    Update-All
})

$profBtn['rename'].Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $n = Show-Ask "New name for '$($p.Name)':" $p.Name
    if (-not $n -or $n -eq $p.Name) { return }
    Invoke-Tool $ProfileScript @('rename', $p.Name, $n)
    Update-All
})

$profBtn['label'].Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $d = $p.Label
    if ($d -eq '<unlabeled>') { $d = '' }
    $n = Show-Ask "Account name to display for '$($p.Name)':" $d
    if (-not $n) { return }
    Invoke-Tool $ProfileScript @('label', $p.Name, $n)
    Update-All
})

$profBtn['delete'].Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Delete profile '$($p.Name)'?`n`nThe saved session for $($p.Label) is removed. You would have to sign into that account again to recreate it.",
        'Claude Switcher', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $ProfileScript @('delete', $p.Name)
    Update-All
})

$profBtn['doctor'].Add_Click({ Invoke-Tool $ProfileScript @('doctor') })

$btnCopySession.Add_Click({
    if ($lvSessions.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a session first.', 'Claude Switcher', 'OK', 'Information')
        return
    }
    if ($script:Profiles.Count -lt 2) {
        [void][System.Windows.Forms.MessageBox]::Show('You need two saved profiles to move a session between accounts.', 'Claude Switcher', 'OK', 'Information')
        return
    }
    $s = $lvSessions.SelectedItems[0].Tag
    $src = $script:Profiles[$cbAccount.SelectedIndex]
    $dst = $null
    foreach ($p in $script:Profiles) { if ($p.Name -ne $src.Name) { $dst = $p; break } }
    if (-not $dst) { return }

    $r = [System.Windows.Forms.MessageBox]::Show(
        "Copy `"$($s.Title)`" to $($dst.Label)?`n`nThe original stays on $($src.Label). Restart Claude to see it.",
        'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $SessionScript @('copy', $s.SessionId, $dst.Name)
    Update-Sessions
})

# --- Tooltips ----------------------------------------------------------------

$tip                = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay   = 20000     # these are long; give people time to read
$tip.InitialDelay   = 400
$tip.ReshowDelay    = 200
$tip.ShowAlways     = $true

$tip.SetToolTip($btnRefresh, 'Re-read accounts, sessions and watcher state from disk. Use this if something changed outside this window.')

$tip.SetToolTip($profBtn['switch'], "Sign the desktop app into the selected account.`nCloses Claude and reopens it. Same as double-clicking the row.")
$tip.SetToolTip($profBtn['add'],    "Guided setup for another account: opens Claude so you can log out and sign in as the new one, then saves that session as a profile.")
$tip.SetToolTip($profBtn['save'],   "Capture the account you are signed into RIGHT NOW as a new profile.`nCloses Claude briefly. Refuses if that account is already saved.")
$tip.SetToolTip($profBtn['rename'], 'Change the profile short name. Does not touch the account or the saved session.')
$tip.SetToolTip($profBtn['label'],  'Set the display name in the Account column. Cosmetic only - the UUID is the real identity.')
$tip.SetToolTip($profBtn['delete'], 'Remove the saved profile. You would have to sign into that account again to recreate it.')
$tip.SetToolTip($profBtn['doctor'], 'Show resolved paths, whether Claude is running, and whether each session file is readable.')
$tip.SetToolTip($lvProfiles,        'Double-click an account to switch to it. The green dot is the account currently signed in.')

$tip.SetToolTip($cbAccount,      "Choose which account's session list to show.")
$tip.SetToolTip($btnCopySession, "Add the selected conversation to the other account's list.`nThe original stays put - both accounts read the same transcript file.`nRestart Claude to see it appear.")
$tip.SetToolTip($lvSessions,     "Sessions belonging to the chosen account. 'MISSING' means the transcript file is gone, so copying it would open empty.")

Update-All
Add-Output 'Use Save current as for your first account, or Add account for your second.'
[void]$form.ShowDialog()
