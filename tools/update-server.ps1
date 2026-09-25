# VOIDBLOOM - send the co-op server to GitHub
#
# Double-click "UPDATE SERVER.bat" one folder up. This checks the server
# files, commits them, pushes to GitHub, and then waits until Render is
# really running this exact file. It compares a fingerprint of index.js
# against the one the live server reports, so "it deployed" is proved
# rather than hoped for.
#
# Deliberately ASCII-only: Windows PowerShell reads a .ps1 with no BOM as
# ANSI, so a curly quote or a long dash in here would arrive as mojibake.

# git and node write ordinary progress to the error stream. With
# ErrorActionPreference = Stop, Windows PowerShell turns that into a
# terminating error and the script would die on a perfectly good push. So
# leave it on Continue and check every exit code by hand instead.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- helpers
function Line { param($c = 'DarkGray') Write-Host ("-" * 64) -ForegroundColor $c }
function Say  { param($m, $c = 'Gray')  Write-Host $m -ForegroundColor $c }
function Ok   { param($m) Write-Host "  ok   " -ForegroundColor Green -NoNewline;  Write-Host $m }
function Info { param($m) Write-Host "       " -NoNewline; Write-Host $m -ForegroundColor DarkGray }
function Warn { param($m) Write-Host "  note " -ForegroundColor Yellow -NoNewline; Write-Host $m }

function Ask {
    param($Label, $Default)
    Write-Host "       $Label " -NoNewline -ForegroundColor DarkGray
    if ($Default) {
        Write-Host "[" -NoNewline -ForegroundColor DarkGray
        Write-Host $Default -NoNewline -ForegroundColor Yellow
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
    }
    $t = Read-Host
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t.Trim()
}

function Yes {
    param($Question)
    Write-Host "       $Question [y/N] " -NoNewline -ForegroundColor DarkGray
    return ((Read-Host) -match '^\s*y')
}

function Stop-Here {
    param($m, $hint)
    Write-Host ""
    Write-Host "  STOP  " -ForegroundColor Red -NoNewline
    Write-Host $m -ForegroundColor White
    if ($hint) { foreach ($h in @($hint)) { Write-Host "        $h" -ForegroundColor DarkGray } }
    Write-Host ""
    Write-Host "        Nothing reached GitHub, so the server your friends are on is untouched." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

# git, three ways: let it talk, keep it quiet, or catch what it said
function Git-Do {
    param([string[]]$GitArgs, $Hint)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { Stop-Here "git $($GitArgs -join ' ') failed - the reason is just above." $Hint }
}
function Git-Code {
    param([string[]]$GitArgs)
    & git @GitArgs 2>&1 | Out-Null
    return $LASTEXITCODE
}
function Git-Text {
    param([string[]]$GitArgs)
    $out = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

# the fingerprint the live server reports: sha1 of index.js with the
# carriage returns taken out, so Windows and Linux agree on the number
function Get-Sig {
    param($Path)
    $t = [System.IO.File]::ReadAllText($Path) -replace "`r", ""
    $h = [System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($t))
    return ([BitConverter]::ToString($h) -replace '-', '').ToLower().Substring(0, 8)
}

function Get-Health {
    param($Base, $Timeout = 20)
    try { return Invoke-RestMethod -Uri ($Base + '/health?t=' + [DateTime]::UtcNow.Ticks) -TimeoutSec $Timeout -ErrorAction Stop }
    catch { return $null }
}

# ---------------------------------------------------------------- set up
$root = Split-Path -Parent $PSScriptRoot          # the server folder
$up   = Split-Path -Parent $root                  # the VOIDBLOOM folder
Set-Location $root

try { Clear-Host } catch { }
Write-Host ""
Write-Host "  V O I D B L O O M " -ForegroundColor Cyan -NoNewline
Write-Host " ship the co-op server" -ForegroundColor DarkGray
Line

$idx = Join-Path $root 'index.js'
if (-not (Test-Path $idx)) {
    Stop-Here "Can't find index.js." "This script belongs in the server folder, inside tools\."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-Here "Git isn't installed on this computer." @(
        "Get it from https://git-scm.com/download/win, click through the installer,",
        "then run this again. Nothing else needs setting up."
    )
}

# ---------------------------------------------------------------- 1. files
Say "1. checking the server files" 'Cyan'

$bytes = (Get-Item $idx).Length
if ($bytes -lt 3000) { Stop-Here "index.js is only $bytes bytes." "That looks like the wrong file, or half of one." }

$srvText = [System.IO.File]::ReadAllText($idx)
if ($srvText -notmatch 'colyseus')  { Stop-Here "index.js doesn't look like the co-op server." }
if ($srvText -notmatch 'undervault') { Stop-Here "index.js has no 'undervault' room in it." }

$pkgPath = Join-Path $root 'package.json'
if (-not (Test-Path $pkgPath)) { Stop-Here "package.json is missing." "Render needs it to install and start the server." }
try { $pkg = [System.IO.File]::ReadAllText($pkgPath) | ConvertFrom-Json -ErrorAction Stop }
catch { Stop-Here "package.json isn't valid JSON - Render's build would fail." $_.Exception.Message }
if (-not $pkg.scripts.start) { Stop-Here "package.json has no start script." }

# if node is on this machine, let it read the file properly. A typo caught
# here is three minutes of Render's build time not wasted.
if (Get-Command node -ErrorAction SilentlyContinue) {
    & node --check $idx
    if ($LASTEXITCODE -ne 0) { Stop-Here "index.js has a syntax error (shown above)." "Fix that line, then run this again." }
    Ok "index.js parses"
} else {
    Info "node isn't on this computer, so the syntax check was skipped"
}

# the game and the server must speak the same protocol or nobody can join
$gamePath  = Join-Path $up 'VOIDBLOOM.html'
$srvProto  = [regex]::Match($srvText, "PROTOCOL\s*=\s*'([^']+)'").Groups[1].Value
$gameText  = ''
if (Test-Path $gamePath) {
    $gameText  = [System.IO.File]::ReadAllText($gamePath)
    $gameProto = [regex]::Match($gameText, "MP_PROTOCOL\s*=\s*'([^']+)'").Groups[1].Value
    if ($srvProto -and $gameProto -and $srvProto -ne $gameProto) {
        Warn "the game speaks '$gameProto' and this server speaks '$srvProto'."
        Info "Players on that game would be turned away until the two match."
        if (-not (Yes "ship it anyway?")) { Stop-Here "Stopped." }
    } elseif ($srvProto) {
        Ok "protocol '$srvProto' matches the game"
    }
}

$want = Get-Sig $idx
Ok ("this build is " + $want + "  (" + [math]::Round($bytes / 1KB) + " KB)")

# ---------------------------------------------------------------- 2. repo
Write-Host ""
Say "2. the GitHub repository" 'Cyan'

$firstRun = -not (Test-Path (Join-Path $root '.git'))
$branch   = 'main'

if ($firstRun) {
    # a fair guess: the same GitHub account as the desktop app's repo
    $owner = 'Icemanboi'
    $deskCfg = Join-Path $up 'desktop\.git\config'
    if (Test-Path $deskCfg) {
        $m = [regex]::Match([System.IO.File]::ReadAllText($deskCfg), 'github\.com[/:]([^/]+)/')
        if ($m.Success) { $owner = $m.Groups[1].Value }
    }

    Info "this folder isn't linked to GitHub yet - setting that up once"
    Write-Host ""
    $remote = (Ask "repository address:" "https://github.com/$owner/voidbloom-server.git") -replace '\s', ''
    # accept whatever GitHub hands you: the address bar, the green Code button,
    # with or without .git, with or without a /tree/main tail
    $m = [regex]::Match($remote, '(?:https?://)?(?:www\.)?github\.com/([^/]+)/([^/#?]+)')
    if ($m.Success) {
        $owner  = $m.Groups[1].Value
        $remote = 'https://github.com/' + $owner + '/' + ($m.Groups[2].Value -replace '\.git$', '') + '.git'
    } elseif ($remote -notmatch '^[\w.-]+@|^/|^[A-Za-z]:\\') {
        # not a GitHub address, not ssh, not a folder on this machine
        Stop-Here "'$remote' doesn't look like a GitHub address." "It should read like https://github.com/you/voidbloom-server"
    }

    Info "knocking on $remote"
    $heads = Git-Text @('ls-remote', '--heads', $remote)
    if ($null -eq $heads) {
        Stop-Here "Couldn't open that repository." @(
            "Two usual reasons:",
            "  - it doesn't exist yet. Make it at https://github.com/new, named exactly",
            "    the last part of the address above, then run this again.",
            "  - GitHub didn't accept the sign-in. A browser window should have asked;",
            "    if it didn't, install Git Credential Manager or GitHub Desktop and retry."
        )
    }
    if     ($heads -match 'refs/heads/main')   { $branch = 'main' }
    elseif ($heads -match 'refs/heads/master') { $branch = 'master' }

    Git-Do @('-c', "init.defaultBranch=$branch", 'init', '--quiet') $null
    Git-Do @('branch', '-M', $branch) $null
    if (Git-Code @('remote', 'add', 'origin', $remote)) { Git-Do @('remote', 'set-url', 'origin', $remote) $null }

    if ($heads) {
        # the repo already holds the files that went up through the web page.
        # Sit this folder on top of that history instead of starting a rival one.
        Git-Do @('fetch', '--quiet', 'origin', $branch) "Check the address, then try again."
        Git-Do @('update-ref', "refs/heads/$branch", 'FETCH_HEAD') $null
        Git-Do @('reset', '--quiet') $null
        Ok "linked to $remote, on top of what is already there"
    } else {
        Info "the repository is empty - this push will be its first commit"
        Ok "linked to $remote"
    }
} else {
    $remote = Git-Text @('remote', 'get-url', 'origin')
    if (-not $remote) {
        Stop-Here "This folder has a .git but no 'origin' remote." "Run: git remote add origin https://github.com/you/voidbloom-server.git"
    }
    $b = Git-Text @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($b -and $b -ne 'HEAD') { $branch = $b }
    $owner = [regex]::Match($remote, 'github\.com[/:]([^/]+)/').Groups[1].Value
    if (-not $owner) { $owner = 'voidbloom' }
    Ok "$remote  ($branch)"
}

# git won't commit for a stranger
if (-not (Git-Text @('config', 'user.email'))) {
    Write-Host ""
    Info "git doesn't know who you are yet. This is only how commits get signed."
    $gName  = Ask "your name:"  $(if ($env:USERNAME) { $env:USERNAME } else { 'Isaac' })
    $gMail  = Ask "your email:" "$owner@users.noreply.github.com"
    if ($gMail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Stop-Here "'$gMail' isn't an email address." "Git signs every commit with one. Run this again and give it any address you like."
    }
    Git-Do @('config', '--global', 'user.name',  $gName) $null
    Git-Do @('config', '--global', 'user.email', $gMail) $null
    Ok "commits will be signed $gName <$gMail>"
}

# ---------------------------------------------------------------- 3. changes
Write-Host ""
Say "3. what is going up" 'Cyan'

Git-Do @('add', '-A') $null
$nothingStaged = ((Git-Code @('diff', '--cached', '--quiet')) -eq 0)

# a push that failed last time leaves work here that GitHub never got
$ahead = 0
$a = Git-Text @('rev-list', '--count', "origin/$branch..HEAD")
if ($a -match '^\d+$') { $ahead = [int]$a }

if ($nothingStaged -and $ahead -gt 0) {
    $word = if ($ahead -eq 1) { 'one change' } else { "$ahead changes" }
    Info "$word from last time never made it to GitHub - sending that now"
} elseif ($nothingStaged) {
    Info "no changes - GitHub already has this exact server"
    Write-Host ""
    if (-not (Yes "restart it on Render anyway?")) {
        Write-Host ""
        Read-Host "Press Enter to close"
        exit 0
    }
    Git-Do @('commit', '--allow-empty', '-m', "Redeploy $want") $null
    Ok "committed"
} else {
    $lines = @((Git-Text @('diff', '--cached', '--name-status')) -split "`n" | Where-Object { $_ })
    foreach ($l in ($lines | Select-Object -First 20)) { Info $l }
    if ($lines.Count -gt 20) { Info ("...and " + ($lines.Count - 20) + " more") }
    Write-Host ""
    $msg = Ask "describe it in a few words:" "Update the co-op server"
    Git-Do @('commit', '-m', $msg) $null
    Ok "committed"
}

# ---------------------------------------------------------------- 4. push
Write-Host ""
Say "4. pushing to GitHub" 'Cyan'

# someone may have edited a file on the GitHub site; take that first
if (-not $firstRun) {
    if ((Git-Code @('pull', '--rebase', 'origin', $branch)) -ne 0) {
        Warn "couldn't line up with what is on GitHub - pushing this as it stands"
    }
}

Git-Do @('push', '-u', 'origin', $branch) @(
    "If it asked you to sign in and that failed, open GitHub Desktop once",
    "(or run: git credential-manager configure) and try again."
)
Ok "pushed - Render has been told"

# ---------------------------------------------------------------- 5. Render
Write-Host ""
Say "5. waiting for Render to run it" 'Cyan'

# the address the game itself is pointed at, so this needs no setting up
$url = ''
if ($gameText) { $url = [regex]::Match($gameText, "MP_SERVER_URL\s*=\s*'([^']+)'").Groups[1].Value }
if (-not $url) { $url = Ask "server address (Enter to skip this check):" '' }

if ($url) {
    $url = $url.TrimEnd('/')
    Info "watching $url/health for build $want"
    $h0 = Get-Health $url
    $before = $null
    # The fingerprint only proves anything if it is different right now. When
    # the same code is being redeployed, the proof has to be the uptime
    # dropping back to nothing instead.
    $bySig = $true
    if ($h0) {
        $before = [int]$h0.up
        if ($h0.sig -eq $want) { $bySig = $false; Info "it is already running this exact code - watching for the restart instead" }
        elseif ($h0.sig)       { Info "right now it is running build $($h0.sig), up $before seconds" }
        else                   { Info "the build up there predates fingerprints, up $before seconds" }
    } else {
        Info "no answer from it yet - asleep, or already restarting"
    }

    $t0 = Get-Date
    $live = $null
    for ($i = 0; $i -lt 36; $i++) {              # up to six minutes
        Start-Sleep -Seconds 10
        $h = Get-Health $url 25
        if ($h) {
            if ($bySig -and $h.sig -and $h.sig -eq $want) { $live = $h; break }
            if (-not $bySig -and $null -ne $before -and [int]$h.up -lt $before) { $live = $h; break }
        }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
    $mins = [math]::Round(((Get-Date) - $t0).TotalSeconds / 60, 1)

    if ($live) {
        Ok "live after $mins min - build $($live.sig), protocol $($live.protocol), cpu $($live.cpu)% of a core, memory $($live.mem) MB"
    } else {
        Warn "it still isn't running this build after $mins minutes."
        Info "Open the Render dashboard, look at Events, then Logs. A red 'Deploy failed'"
        Info "there will say which line it choked on. Your old server keeps running until"
        Info "a build succeeds, so nobody has been cut off."
    }
}

# ---------------------------------------------------------------- done
$repoPage = $remote -replace '\.git$', ''
Write-Host ""
Line 'Cyan'
Write-Host "  Done." -ForegroundColor White
Write-Host ""
Info "repository:  $repoPage"
Info "render:      https://dashboard.render.com"
if ($url) { Info "health:      $url/health" }
Write-Host ""
Info "Players don't have to do anything - only the server changed. If you"
Info "changed the game as well, send them the new file or run UPDATE GAME.bat."
Line 'Cyan'
Write-Host ""

if (Yes "open the repository in a browser?") { Start-Process $repoPage }

Write-Host ""
Read-Host "Press Enter to close"
