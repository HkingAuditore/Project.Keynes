#requires -version 3
<#
  Project.Keynes web package receiver - runs ON the Windows/IIS server.

  Why this exists: the workstation cannot reach the server over SSH/SMB/WinRM
  (the network path only relays plain HTTP), and IIS has no upload endpoint.
  This script is that endpoint: a single small HTTP listener that accepts a
  resumable chunked upload and swaps the IIS application directory atomically,
  keeping the previous version as a timestamped backup next to it.

  Wire protocol (all requests carry the X-PK-Token header):

      GET    /health
      POST   /upload/begin?app=<dir>&size=<bytes>[&name=<zip name>]
      PUT    /upload/chunk?session=<id>&offset=<bytes>     body = raw chunk
      POST   /upload/finish?session=<id>
      DELETE /upload?session=<id>

  Chunking is deliberate: the workstation talks to the server through a
  transparent gateway whose request-body limit is unknown, so the package goes
  up in fixed-size pieces and any single piece can be retried. `offset` makes
  the upload resumable; a stale offset is answered with 409 plus the true size
  so the client can catch up instead of restarting.

  One-time setup (elevated PowerShell, on the server):

      powershell -NoProfile -ExecutionPolicy Bypass -File .\pk_web_receiver.ps1 -Install

  It prints the token and the JSON the workstation needs, registers a scheduled
  task (SYSTEM, at startup) and opens the Windows firewall port. It cannot open
  the cloud security group - do that in the console (same port).

  Other modes:

      -Status                 what is installed, listening and configured
      -Uninstall              remove task + firewall rule + state
      -Foreground             run in this console (no task); useful to test
      -TargetRoot <dir>       skip appcmd detection and use this physical dir

  No site-specific value (host, IP, domain, token) lives in the repository: the
  token is generated here and copied to the workstation config by hand.
#>
[CmdletBinding()]
param(
    [int]$Port = 8099,
    [string]$AppName = 'web-debug',
    [string]$Token = '',
    [string]$TargetRoot = '',
    [string]$StateDir = (Join-Path $env:ProgramData 'pk-web-receiver'),
    [int]$MaxBytes = 400MB,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Diagnose,
    [switch]$StartHidden,
    [switch]$Stop,
    [switch]$RegisterAutostart,
    [switch]$UnregisterAutostart,
    [switch]$NoProbe,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'
$TaskName = 'PKWebReceiver'
$FirewallRule = 'PK Web Receiver'
$script:LogPath = Join-Path $StateDir 'receiver.log'
$script:ZipEntryAssembly = $null
$script:Token = $Token
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }

# ---------------------------------------------------------------- logging ---
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Foreground) { Write-Host $line }
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Assert-ZipApi {
    if ($script:ZipEntryAssembly) { return }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:ZipEntryAssembly = $true
}

# Native tools (schtasks/netsh/icacls) write progress to stderr, and with
# $ErrorActionPreference='Stop' PowerShell turns that into a terminating error.
# Run them with the preference relaxed and hand back output + exit code.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
        $lines = @()
        foreach ($item in @($out)) { $lines += [string]$item }
        return [pscustomobject]@{ Output = $lines; Code = $code }
    } finally {
        $ErrorActionPreference = $previous
    }
}

# --------------------------------------------------------------- target ------
# Resolve every physical directory IIS serves for /<AppName>/.
#
# This follows the older deploy-web-debug.ps1 on purpose: that box has both an
# IP site and a domain site, and updating only one of them leaves "new package on
# the IP, old package on the domain" - the exact split its README warns about. So
# every virtual directory ending in /<AppName> is returned, not just the first.
function Resolve-TargetRoots {
    if ($TargetRoot) {
        $single = $TargetRoot.TrimEnd('\')
        return @([pscustomobject]@{
            Site      = '(explicit)'
            Target    = $single
            Url       = ''
            ProbeUrl  = ''
            ProbeHost = ''
            HasHttps  = $false
        })
    }
    $appcmd = $env:PK_IIS_APPCMD
    if (-not $appcmd) { $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe' }
    if (-not (Test-Path -LiteralPath $appcmd)) {
        throw "IIS appcmd.exe not found: $appcmd (is IIS installed?)"
    }
    $sites = New-Object System.Collections.ArrayList
    foreach ($line in (& $appcmd list site)) {
        if ($line -match '^SITE "([^"]+)" \(id:(\d+),bindings:(.*?),state:(\w+)\)') {
            $entry = [pscustomobject]@{
                Name     = $matches[1]
                Bindings = $matches[3]
                Root     = ''
                Hosts    = (New-Object System.Collections.ArrayList)
                HasHttps = $false
            }
            foreach ($binding in ($entry.Bindings -split ',')) {
                if (-not $binding) { continue }
                if ($binding -match '^(https?)/([^:]*):(\d+):(.*)$') {
                    $proto = $matches[1]
                    $port = $matches[3]
                    $hostName = $matches[4]
                    if ($proto -eq 'https') { $entry.HasHttps = $true }
                    if ($hostName -and $hostName -ne '*') { [void]$entry.Hosts.Add($hostName) }
                }
            }
            [void]$sites.Add($entry)
        }
    }

    $targets = New-Object System.Collections.ArrayList
    foreach ($line in (& $appcmd list vdir)) {
        if ($line -match '^VDIR "(.+?)/" \(physicalPath:(.+)\)$') {
            $vdir = $matches[1]
            $physical = $matches[2]
            $siteName = ($vdir -split '/')[0]
            foreach ($s in $sites) {
                if ($s.Name -eq $siteName -and -not $s.Root) { $s.Root = $physical }
            }
            if ($vdir -match ('/' + [regex]::Escape($AppName) + '$')) {
                $site = $sites | Where-Object { $_.Name -eq $siteName } | Select-Object -First 1
                $hosts = @()
                $hasHttps = $false
                if ($site) { $hosts = @($site.Hosts); $hasHttps = $site.HasHttps }
                $probeHost = ''
                if ($hosts.Count -gt 0) { $probeHost = [string]$hosts[0] }
                $url = ''
                if ($probeHost) {
                    $scheme = 'http'
                    if ($hasHttps) { $scheme = 'https' }
                    $url = ('{0}://{1}/{2}/' -f $scheme, $probeHost, $AppName)
                }
                [void]$targets.Add([pscustomobject]@{
                    Site      = $siteName
                    Target    = $physical.TrimEnd('\')
                    Url       = $url
                    ProbeUrl  = ('http://127.0.0.1/{0}/index.html' -f $AppName)
                    ProbeHost = $probeHost
                    HasHttps  = $hasHttps
                })
                Write-Log ("target from appcmd: vdir={0} physical={1} https={2}" -f $vdir, $physical, $hasHttps)
            }
        }
    }
    if ($targets.Count -gt 0) { return @($targets) }

    $site = $sites | Where-Object { $_.Bindings -match 'http/[^,:]*:80:' } | Select-Object -First 1
    if (-not $site) { $site = $sites | Select-Object -First 1 }
    if (-not $site -or -not $site.Root) { throw "cannot resolve a site root for /$AppName/" }
    $fallback = Join-Path $site.Root $AppName
    Write-Log ("target from site root: site={0} root={1} -> {2}" -f $site.Name, $site.Root, $fallback)
    $probeHost = ''
    if (@($site.Hosts).Count -gt 0) { $probeHost = [string]@($site.Hosts)[0] }
    $fallbackUrl = ''
    if ($probeHost) {
        $fallbackUrl = ('{0}://{1}/{2}/' -f $(if ($site.HasHttps) { 'https' } else { 'http' }), $probeHost, $AppName)
    }
    return @([pscustomobject]@{
        Site      = $site.Name
        Target    = $fallback.TrimEnd('\')
        Url       = $fallbackUrl
        ProbeUrl  = ('http://127.0.0.1/{0}/index.html' -f $AppName)
        ProbeHost = $probeHost
        HasHttps  = $site.HasHttps
    })
}

# First target only - used by /health and by callers that just want one path.
function Resolve-TargetRoot {
    $all = @(Resolve-TargetRoots)
    if ($all.Count -eq 0) { throw "no target resolved for /$AppName/" }
    return $all[0].Target
}

# ------------------------------------------------------------ site update ----
$WebConfigTemplate = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <add name="Cross-Origin-Opener-Policy" value="same-origin" />
        <add name="Cross-Origin-Embedder-Policy" value="require-corp" />
        <add name="Cross-Origin-Resource-Policy" value="same-origin" />
      </customHeaders>
    </httpProtocol>
    <staticContent>
      <remove fileExtension=".wasm" />
      <mimeMap fileExtension=".wasm" mimeType="application/wasm" />
      <remove fileExtension=".pck" />
      <mimeMap fileExtension=".pck" mimeType="application/octet-stream" />
      <remove fileExtension=".worklet.js" />
      <mimeMap fileExtension=".worklet.js" mimeType="text/javascript" />
    </staticContent>
  </system.webServer>
</configuration>
'@

$IndexHtmlTemplate = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>Project.Keynes Web</title>
  <meta http-equiv="refresh" content="0; url=ProjectKeynes.html">
</head>
<body style="background:#111;color:#ddd;font-family:sans-serif">
  <p>Loading <a href="ProjectKeynes.html" style="color:#6cf">ProjectKeynes.html</a> ...</p>
</body>
</html>
'@

# Browser-side self check, deployed next to the game. Same purpose as the
# check.html that shipped with the older hand-made deploy package: the threads
# build needs a secure context plus cross-origin isolation, and over plain http
# on a bare IP neither is available - which looks like a broken game, not a
# header problem. ASCII only, so it renders the same whatever the codepage is.
$CheckHtmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>COI check</title>
<style>
  body{margin:0;padding:16px;background:#111;color:#ddd;font:14px/1.7 ui-monospace,Consolas,monospace}
  h1{font-size:16px;color:#6cf;margin:0 0 12px}
  table{border-collapse:collapse;width:100%}
  td{padding:4px 8px;border-bottom:1px solid #2a2a2a;vertical-align:top;word-break:break-all}
  td:first-child{color:#888;white-space:nowrap;width:42%}
  .ok{color:#4caf50;font-weight:700}
  .bad{color:#f44336;font-weight:700}
</style>
</head>
<body>
<h1>Cross-Origin Isolation check</h1>
<div id="verdict" style="margin-bottom:12px"></div>
<table id="rows"></table>
<p style="color:#666;margin-top:16px">
  Godot's threads build needs isSecureContext, crossOriginIsolated and SharedArrayBuffer.
  Plain http on a bare IP gives you none of them; use https (a domain with a certificate).
</p>
<script>
(function () {
  var sb = (typeof SharedArrayBuffer !== 'undefined');
  var coi = (window.crossOriginIsolated === true);
  var sec = (window.isSecureContext === true);
  var rows = [
    ['URL', location.href],
    ['isSecureContext', sec],
    ['crossOriginIsolated', coi],
    ['SharedArrayBuffer', sb ? 'function' : String(typeof SharedArrayBuffer)],
    ['WebAssembly', typeof WebAssembly],
    ['hardwareConcurrency', navigator.hardwareConcurrency],
    ['WebGL2', (function () {
        try {
          var c = document.createElement('canvas');
          return !!(c.getContext && c.getContext('webgl2'));
        } catch (e) { return 'error'; }
      })()]
  ];
  var t = document.getElementById('rows');
  for (var i = 0; i < rows.length; i++) {
    var tr = document.createElement('tr');
    var a = document.createElement('td');
    a.textContent = rows[i][0];
    var b = document.createElement('td');
    b.textContent = String(rows[i][1]);
    if (typeof rows[i][1] === 'boolean') { b.className = rows[i][1] ? 'ok' : 'bad'; }
    tr.appendChild(a); tr.appendChild(b); t.appendChild(tr);
  }
  var v = document.getElementById('verdict');
  if (sec && coi && sb) {
    v.className = 'ok';
    v.textContent = 'OK: this browser can run the threads build.';
  } else if (!sec) {
    v.className = 'bad';
    v.textContent = 'FAIL: not a secure context. Open the site over https, not http on an IP.';
  } else if (!coi) {
    v.className = 'bad';
    v.textContent = 'FAIL: not cross-origin isolated. Check that web.config is being served (COOP/COEP headers).';
  } else {
    v.className = 'bad';
    v.textContent = 'FAIL: isolated but this engine does not expose SharedArrayBuffer.';
  }
  document.title = (sec && coi && sb) ? 'COI OK' : 'COI FAIL';
})();
</script>
</body>
</html>
'@

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, $Text, $utf8Bom)
}

# Local HEAD against the site IIS just started serving. Used for 500.19 recovery
# and to report a per-site status; a refused connection (no IIS on this machine)
# is reported as "unknown", never treated as a failed deploy.
function Invoke-SiteProbe {
    param([string]$Url, [string]$HostHeader)
    if (-not $Url) { return [pscustomobject]@{ Code = 0; Error = 'no url'; Detail = 'unknown' } }
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = 8000
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        if ($HostHeader) {
            try { $request.Host = $HostHeader } catch { }
        }
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $response.Close()
        return [pscustomobject]@{ Code = $code; Error = ''; Detail = ('HTTP ' + $code) }
    } catch [Net.WebException] {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($code -eq 0) { return [pscustomobject]@{ Code = 0; Error = $_.Exception.Message; Detail = 'no response from 127.0.0.1 (IIS not reachable here?)' } }
        return [pscustomobject]@{ Code = $code; Error = $_.Exception.Message; Detail = ('HTTP ' + $code) }
    } catch {
        return [pscustomobject]@{ Code = 0; Error = $_.Exception.Message; Detail = 'probe error' }
    }
}

# 500.19 means the directory is not allowed to override the sections in
# web.config; registering it as an IIS application fixes that (same fallback the
# older deploy package used).
function Enable-IisApplication {
    param([string]$Site, [string]$App, [string]$PhysicalPath)
    if (-not $Site -or $Site -eq '(explicit)') { return $false }
    $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    $result = Invoke-Native $appcmd @('add', 'app', ('/site.name:' + $Site), ('/path:/' + $App), ('/physicalPath:' + $PhysicalPath))
    Write-Log ("appcmd add app site={0} path=/{1} exit={2}" -f $Site, $App, $result.Code)
    return ($result.Code -eq 0)
}

# Swap one site directory for the staged copy. The previous directory is renamed
# to <target>.bak-<stamp> so a rollback is one rename away; if the second rename
# fails the original name is restored.
function Update-OneSite {
    param([pscustomobject]$TargetInfo, [string]$StagingDir, [string]$Stamp)

    $target = $TargetInfo.Target
    $parent = Split-Path -Parent $target
    $leaf = Split-Path -Leaf $target
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $newDir = Join-Path $parent ($leaf + '.new-' + $Stamp)
    $bakDir = Join-Path $parent ($leaf + '.bak-' + $Stamp)
    if (Test-Path -LiteralPath $newDir) { Remove-Item -LiteralPath $newDir -Recurse -Force }

    Write-Log ("copying staging -> {0}" -f $newDir)
    Copy-Item -LiteralPath $StagingDir -Destination $newDir -Recurse -Force

    $old = $null
    if (Test-Path -LiteralPath $target) {
        Write-Log ("previous version -> {0}" -f $bakDir)
        Rename-Item -LiteralPath $target -NewName (Split-Path -Leaf $bakDir)
        $old = $bakDir
    }
    try {
        Rename-Item -LiteralPath $newDir -NewName $leaf
    } catch {
        if ($old) { try { Rename-Item -LiteralPath $old -NewName $leaf } catch { } }
        throw
    }

    # IIS worker identities need read access to what SYSTEM just created.
    try { [void](Invoke-Native 'icacls.exe' @($target, '/grant', 'IIS_IUSRS:(OI)(CI)(RX)', '/T')) } catch { Write-Log 'icacls grant skipped' 'WARN' }

    # Keep the two newest backups; drop older ones.
    $backups = @(Get-ChildItem -LiteralPath $parent -Directory -Filter ($leaf + '.bak-*') | Sort-Object Name -Descending)
    for ($i = 2; $i -lt $backups.Count; $i++) {
        Write-Log ("pruning old backup {0}" -f $backups[$i].FullName)
        Remove-Item -LiteralPath $backups[$i].FullName -Recurse -Force
    }

    $probe = Invoke-SiteProbe -Url $TargetInfo.ProbeUrl -HostHeader $TargetInfo.ProbeHost
    if ($probe.Code -eq 500) {
        Write-Log 'probe returned 500 - trying to register the directory as an IIS application'
        if (Enable-IisApplication -Site $TargetInfo.Site -App $AppName -PhysicalPath $target) {
            Start-Sleep -Seconds 2
            $probe = Invoke-SiteProbe -Url $TargetInfo.ProbeUrl -HostHeader $TargetInfo.ProbeHost
        }
    }

    $files = @(Get-ChildItem -LiteralPath $target -Recurse -File)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    Write-Log ("updated {0}: {1} files, {2} bytes, probe={3}" -f $target, $files.Count, $bytes, $probe.Detail)

    $url = $TargetInfo.Url
    return [pscustomobject]@{
        site       = $TargetInfo.Site
        target     = $target
        url        = $url
        https      = [bool]$TargetInfo.HasHttps
        backup     = [string]$bakDir
        probe      = $probe.Detail
        probe_code = [int]$probe.Code
        file_count = $files.Count
        bytes      = [int64]$bytes
    }
}

# Deploy to every resolved target. One staging directory is extracted once and
# copied per site, so the package is unzipped once no matter how many sites exist.
function Update-Sites {
    param([string]$ZipPath)

    Assert-ZipApi
    $targets = @(Resolve-TargetRoots)
    if ($targets.Count -eq 0) { throw "no target resolved for /$AppName/" }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $staging = Join-Path $StateDir ('staging-' + $stamp)

    try {
        Write-Log ("extracting {0} -> {1} ({2} target(s))" -f $ZipPath, $staging, $targets.Count)
        [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $staging)

        $html = @(Get-ChildItem -LiteralPath $staging -Filter '*.html' -File)
        $pck = @(Get-ChildItem -LiteralPath $staging -Filter '*.pck' -File)
        if ($html.Count -eq 0 -or $pck.Count -eq 0) {
            throw ("package rejected: it has {0} html and {1} pck file(s); a Godot web export has both" -f $html.Count, $pck.Count)
        }
        Write-TextFile -Path (Join-Path $staging 'web.config') -Text $WebConfigTemplate
        Write-TextFile -Path (Join-Path $staging 'index.html') -Text $IndexHtmlTemplate
        Write-TextFile -Path (Join-Path $staging 'check.html') -Text $CheckHtmlTemplate

        $buildId = ''
        $manifest = Join-Path $staging 'manifest.json'
        if (Test-Path -LiteralPath $manifest) {
            try { $buildId = [string](Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).build_id } catch { }
        }

        $results = @()
        $failed = $null
        foreach ($t in $targets) {
            try {
                $results += Update-OneSite -TargetInfo $t -StagingDir $staging -Stamp $stamp
            } catch {
                $failed = $_
                Write-Log ("update failed for {0}: {1}" -f $t.Target, $_.Exception.Message) 'ERROR'
                break
            }
        }
        if ($failed) { throw $failed }

        $totalFiles = 0
        $totalBytes = [int64]0
        foreach ($r in $results) { $totalFiles += $r.file_count; $totalBytes += $r.bytes }
        $first = $results[0]
        Write-Log ("updated {0} site(s), {1} files, {2} bytes, build_id={3}" -f $results.Count, $totalFiles, $totalBytes, $buildId)

        return [pscustomobject]@{
            ok           = $true
            build_id     = $buildId
            site_count   = $results.Count
            file_count   = $totalFiles
            bytes        = $totalBytes
            target       = $first.target
            backup       = $first.backup
            url          = $first.url
            sites        = $results
        }
    } finally {
        if (Test-Path -LiteralPath $staging) {
            try { Remove-Item -LiteralPath $staging -Recurse -Force } catch { }
        }
    }
}

# --------------------------------------------------------------- sessions ----
function Get-SessionDir {
    param([string]$Session)
    if ($Session -notmatch '^[A-Za-z0-9]{6,40}$') { throw 'bad session id' }
    $dir = Join-Path (Join-Path $StateDir 'sessions') $Session
    return $dir
}

function Invoke-Begin {
    param([string]$App, [string]$Size, [string]$Name, [string]$Sha256)
    $appName = $App
    if (-not $appName) { $appName = $AppName }
    if ($appName -notmatch '^[A-Za-z0-9._-]{1,63}$') { throw 'bad app name' }
    $bytes = [int64]0
    if (-not [int64]::TryParse($Size, [ref]$bytes)) { throw 'bad size' }
    if ($bytes -le 0 -or $bytes -gt $MaxBytes) { throw ("size out of range (max {0} bytes)" -f $MaxBytes) }

    $session = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $dir = Get-SessionDir $session
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $meta = @{ app = $appName; size = $bytes; name = $Name; sha256 = $Sha256.ToLowerInvariant(); created = (Get-Date -Format 'o') }
    $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8
    [IO.File]::WriteAllBytes((Join-Path $dir 'payload.part'), (New-Object byte[] 0))
    Write-Log ("begin session={0} app={1} size={2}" -f $session, $appName, $bytes)
    return [pscustomobject]@{ ok = $true; session = $session; app = $appName; size = $bytes }
}

function Invoke-Chunk {
    param([string]$Session, [string]$Offset, [System.IO.Stream]$Body, [int64]$Length)
    $dir = Get-SessionDir $Session
    $part = Join-Path $dir 'payload.part'
    if (-not (Test-Path -LiteralPath $part)) { throw 'unknown session' }
    $offsetValue = [int64]0
    if (-not [int64]::TryParse($Offset, [ref]$offsetValue)) { throw 'bad offset' }
    $current = (Get-Item -LiteralPath $part).Length
    if ($offsetValue -ne $current) {
        return [pscustomobject]@{ ok = $false; conflict = $true; expected_offset = $current }
    }
    $fs = [IO.File]::Open($part, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] 262144
        $remaining = $Length
        while ($remaining -gt 0) {
            $want = [int][Math]::Min($buffer.Length, $remaining)
            $read = $Body.Read($buffer, 0, $want)
            if ($read -le 0) { throw 'client closed the connection mid-chunk' }
            $fs.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $fs.Flush()
    } finally {
        $fs.Dispose()
    }
    $now = (Get-Item -LiteralPath $part).Length
    return [pscustomobject]@{ ok = $true; received = $now; consumed = $true }
}

function Invoke-Finish {
    param([string]$Session)
    $dir = Get-SessionDir $Session
    $part = Join-Path $dir 'payload.part'
    $metaPath = Join-Path $dir 'meta.json'
    if (-not (Test-Path -LiteralPath $part)) { throw 'unknown session' }
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $have = (Get-Item -LiteralPath $part).Length
    if ($have -ne [int64]$meta.size) {
        return [pscustomobject]@{ ok = $false; incomplete = $true; received = $have; size = [int64]$meta.size }
    }
    $zip = Join-Path $dir 'package.zip'
    Move-Item -LiteralPath $part -Destination $zip -Force
    Write-Log ("finish session={0}: {1} bytes" -f $Session, $have)
    if ($meta.sha256) {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $meta.sha256) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            throw ("package checksum mismatch (expected {0}, got {1}); upload again" -f $meta.sha256, $actual)
        }
        Write-Log 'checksum ok'
    }
    try {
        $result = Update-Sites -ZipPath $zip
    } catch {
        Write-Log ("update failed: {0}" -f $_.Exception.Message) 'ERROR'
        throw
    } finally {
        # The package itself is not kept (it is reproducible on the workstation);
        # the previous site directory next to the target is the rollback.
        try { Remove-Item -LiteralPath $dir -Recurse -Force } catch { }
    }
    return $result
}

function Invoke-Abort {
    param([string]$Session)
    try { $dir = Get-SessionDir $Session; if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } } catch { }
    return [pscustomobject]@{ ok = $true }
}

# ------------------------------------------------------------- http layer ----
function Drain-Body {
    # A response sent before the request body is consumed makes Windows close the
    # socket with unread data, which the client sees as a reset instead of our
    # status line (this bit us on the 409 resume path). Read the rest first.
    param([System.IO.Stream]$Body, [int64]$Length)
    if ($Length -le 0) { return }
    if ($Length -gt 32MB) { return }
    $buffer = New-Object byte[] 262144
    $remaining = $Length
    try {
        while ($remaining -gt 0) {
            $want = [int][Math]::Min($buffer.Length, $remaining)
            $read = $Body.Read($buffer, 0, $want)
            if ($read -le 0) { break }
            $remaining -= $read
        }
    } catch { }
}

function Read-HeaderBlock {
    param([System.IO.Stream]$Stream, [int]$Limit = 16384)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $window = New-Object byte[] 4
    $count = 0
    while ($count -lt $Limit) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        $bytes.Add([byte]$b)
        $count++
        if ($bytes.Count -ge 4) {
            $n = $bytes.Count
            if ($bytes[$n - 1] -eq 10 -and $bytes[$n - 2] -eq 13 -and $bytes[$n - 3] -eq 10 -and $bytes[$n - 4] -eq 13) { break }
        }
    }
    return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Parse-Query {
    param([string]$Query)
    $result = @{}
    if (-not $Query) { return $result }
    foreach ($pair in $Query.Split('&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $k = [Uri]::UnescapeDataString($kv[0])
        $v = ''
        if ($kv.Count -gt 1) { $v = [Uri]::UnescapeDataString($kv[1]) }
        $result[$k] = $v
    }
    return $result
}

function Send-Response {
    param([System.IO.Stream]$Stream, [int]$Code, [string]$Json)
    $reason = 'OK'
    if ($Code -eq 400) { $reason = 'Bad Request' }
    elseif ($Code -eq 401) { $reason = 'Unauthorized' }
    elseif ($Code -eq 409) { $reason = 'Conflict' }
    elseif ($Code -eq 413) { $reason = 'Payload Too Large' }
    elseif ($Code -eq 500) { $reason = 'Internal Server Error' }
    elseif ($Code -eq 404) { $reason = 'Not Found' }
    $body = [Text.Encoding]::UTF8.GetBytes($Json)
    $head = "HTTP/1.1 $Code $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Handle-Client {
    param([Net.Sockets.TcpClient]$Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 60000
    $header = Read-HeaderBlock -Stream $stream
    if (-not $header) { return }
    $lines = $header.Split("`r`n")
    $requestLine = $lines[0]
    if ($requestLine -notmatch '^(GET|POST|PUT|DELETE|HEAD)\s+(\S+)\s+HTTP/1\.\d$') {
        Send-Response -Stream $stream -Code 400 -Json '{"ok":false,"error":"bad request line"}'
        return
    }
    $method = $matches[1]
    $targetUrl = $matches[2]
    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([^:]+):\s*(.*)$') {
            $headers[$matches[1].ToLowerInvariant()] = $matches[2].Trim()
        }
    }
    $path = $targetUrl
    $query = ''
    $qi = $targetUrl.IndexOf('?')
    if ($qi -ge 0) { $path = $targetUrl.Substring(0, $qi); $query = $targetUrl.Substring($qi + 1) }
    $q = Parse-Query -Query $query

    $length = [int64]0
    if ($headers.ContainsKey('content-length')) { [int64]::TryParse($headers['content-length'], [ref]$length) | Out-Null }
    if ($headers.ContainsKey('transfer-encoding')) {
        Drain-Body -Body $stream -Length $length
        Send-Response -Stream $stream -Code 400 -Json '{"ok":false,"error":"chunked request bodies are not supported; send Content-Length"}'
        return
    }
    if ($headers.ContainsKey('expect')) {
        $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        $stream.Write($cont, 0, $cont.Length); $stream.Flush()
    }

    $authOk = $script:Token -and $headers.ContainsKey('x-pk-token') -and ($headers['x-pk-token'] -eq $script:Token)
    if (-not $authOk) {
        Write-Log ("401 {0} {1} from {2}" -f $method, $path, $Client.Client.RemoteEndPoint) 'WARN'
        Drain-Body -Body $stream -Length $length
        Send-Response -Stream $stream -Code 401 -Json '{"ok":false,"error":"bad or missing X-PK-Token"}'
        return
    }

    # One response path: handlers only set $code/$json, and whatever is left of the
    # request body is drained before answering (see Drain-Body).
    $code = 200
    $json = '{"ok":true}'
    $consumed = $false
    try {
        if ($method -eq 'GET' -and $path -eq '/health') {
            $targetInfo = @()
            $targetText = 'unresolved'
            try {
                $targetInfo = @(Resolve-TargetRoots)
                $paths = @()
                foreach ($t in $targetInfo) { $paths += $t.Target }
                if ($paths.Count -gt 0) { $targetText = ($paths -join '; ') }
            } catch {
                $targetText = 'unresolved: ' + $_.Exception.Message
            }
            $payload = [pscustomobject]@{
                ok        = $true
                version   = 2
                app       = $AppName
                target    = $targetText
                targets   = $targetInfo
                max_bytes = $MaxBytes
                time      = (Get-Date -Format 'o')
                ps        = $PSVersionTable.PSVersion.ToString()
            }
            $json = $payload | ConvertTo-Json -Compress -Depth 6
        } elseif ($method -eq 'POST' -and $path -eq '/upload/begin') {
            $begin = Invoke-Begin -App $q['app'] -Size $q['size'] -Name $q['name'] -Sha256 $q['sha256']
            $json = $begin | ConvertTo-Json -Compress
        } elseif ($method -eq 'PUT' -and $path -eq '/upload/chunk') {
            $chunkResult = Invoke-Chunk -Session $q['session'] -Offset $q['offset'] -Body $stream -Length $length
            $consumed = ($chunkResult.consumed -eq $true)
            if ($chunkResult.conflict) { $code = 409 }
            $json = $chunkResult | ConvertTo-Json -Compress -Depth 4
        } elseif ($method -eq 'POST' -and $path -eq '/upload/finish') {
            $finishResult = Invoke-Finish -Session $q['session']
            if ($finishResult.incomplete) { $code = 409 }
            $json = $finishResult | ConvertTo-Json -Compress -Depth 6
        } elseif ($method -eq 'DELETE' -and $path -eq '/upload') {
            $abort = Invoke-Abort -Session $q['session']
            $json = $abort | ConvertTo-Json -Compress
        } else {
            $code = 404
            $json = '{"ok":false,"error":"unknown route"}'
        }
    } catch {
        Write-Log ("{0} {1} {2}: {3}" -f 500, $method, $path, $_.Exception.Message) 'ERROR'
        $code = 500
        $msg = $_.Exception.Message -replace '\\', '\\\\' -replace '"', '\"'
        $json = '{"ok":false,"error":"' + $msg + '"}'
    }
    if (-not $consumed) { Drain-Body -Body $stream -Length $length }
    Send-Response -Stream $stream -Code $code -Json $json
}

function Start-Receiver {
    Assert-ZipApi
    if (-not $script:Token) {
        $tokenPath = Join-Path $StateDir 'token.txt'
        if (Test-Path -LiteralPath $tokenPath) {
            $script:Token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        } else {
            throw 'no token: pass -Token or run -Install first'
        }
    }
    $listener = New-Object Net.Sockets.TcpListener -ArgumentList ([Net.IPAddress]::Any), $Port
    $listener.Start()
    Write-Log ("listening on 0.0.0.0:{0} app={1} state={2}" -f $Port, $AppName, $StateDir)
    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try { Handle-Client -Client $client } catch { Write-Log ("client error: {0}" -f $_.Exception.Message) 'ERROR' }
            finally { try { $client.Close() } catch { } }
        }
    } finally {
        $listener.Stop()
        Write-Log 'listener stopped'
    }
}

# ------------------------------------------------------------------- setup ---
function New-Token {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Command line for the child/listener process. Carries every setting that the
# child cannot infer, so relaunching it later reproduces the same configuration.
# Persist the token so a child process (hidden or via a scheduled task) can read
# it without the caller repeating -Token on every command line.
function Save-Token {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    $tokenPath = Join-Path $StateDir 'token.txt'
    if (-not $script:Token) {
        if (Test-Path -LiteralPath $tokenPath) { $script:Token = (Get-Content -LiteralPath $tokenPath -Raw).Trim() }
        else { $script:Token = New-Token }
    }
    Set-Content -LiteralPath $tokenPath -Value $script:Token -Encoding ASCII
    return $script:Token
}

function Get-ChildArguments {
    $text = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Port {1} -AppName "{2}" -StateDir "{3}"' -f `
        $script:ScriptPath, $Port, $AppName, $StateDir
    if ($TargetRoot) { $text += (' -TargetRoot "{0}"' -f $TargetRoot) }
    # -Foreground means "listen in this process"; the window is hidden by the
    # caller (scheduled task / Start-Process), so the child never shows a console.
    $text += ' -Foreground'
    return $text
}

# Without an inbound rule the listener is unreachable from the workstation, and
# the only symptom is a timeout on --health. Every path that starts the receiver
# therefore installs the rule (idempotent).
function Ensure-FirewallRule {
    [void](Invoke-Native 'netsh.exe' @('advfirewall', 'firewall', 'delete', 'rule', "name=$FirewallRule"))
    $add = Invoke-Native 'netsh.exe' @('advfirewall', 'firewall', 'add', 'rule', "name=$FirewallRule", 'dir=in', 'action=allow', 'protocol=TCP', "localport=$Port")
    if ($add.Code -eq 0) {
        Write-Host ("    firewall  : TCP {0} allowed (rule '{1}')" -f $Port, $FirewallRule) -ForegroundColor Green
    } else {
        Write-Host ("    firewall  : could not add the rule (exit {0}): {1}" -f $add.Code, ($add.Output -join ' ')) -ForegroundColor Yellow
    }
}

function Install-Receiver {
    [void](Save-Token)

    $scriptPath = $script:ScriptPath
    $targetList = @()
    try { $targetList = @(Resolve-TargetRoots) } catch { $targetList = @() }

    # Task creation needs the Task Scheduler service, and on this generation of
    # Windows it writes the task file through TxF, which needs KtmRm. A stopped
    # KtmRm is what produces "the operation was made in the context of a
    # transaction that is no longer active" from schtasks.
    Write-Host '  checking services (Schedule, KtmRm) ...'
    foreach ($name in @('Schedule', 'KtmRm')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Host ("    {0,-9} : not present" -f $name); continue }
        Write-Host ("    {0,-9} : {1}" -f $name, $svc.Status)
        if ($svc.Status -eq 'Running') { continue }
        try {
            Start-Service -Name $name
            Write-Host ("    {0,-9} : started" -f $name)
        } catch {
            Write-Host ("    {0,-9} : start failed ({1})" -f $name, $_.Exception.Message) -ForegroundColor Yellow
            # A disabled KtmRm breaks task creation outright; enabling it on demand
            # is the difference between "works" and ERROR_TRANSACTION_NOT_ACTIVE.
            $config = Invoke-Native 'sc.exe' @('config', $name, 'start=', 'demand')
            Write-Host ("    {0,-9} : sc config -> exit {1}" -f $name, $config.Code)
            try {
                Start-Service -Name $name
                Write-Host ("    {0,-9} : started after enabling" -f $name) -ForegroundColor Green
            } catch {
                Write-Host ("    {0,-9} : still not running" -f $name) -ForegroundColor Yellow
            }
        }
    }

    $taskArguments = Get-ChildArguments
    $installed = $false
    $how = ''

    # Preferred: the ScheduledTasks module (no shell-out, clearer errors).
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        $installed = $true
        $how = 'Register-ScheduledTask'
    } catch {
        Write-Host ("    Register-ScheduledTask failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    if (-not $installed) {
        $create = Invoke-Native 'schtasks.exe' @('/create', '/tn', $TaskName, '/tr', $taskArguments, '/sc', 'onstart', '/ru', 'SYSTEM', '/rl', 'HIGHEST', '/f')
        if ($create.Code -eq 0) {
            [void](Invoke-Native 'schtasks.exe' @('/run', '/tn', $TaskName))
            $installed = $true
            $how = 'schtasks'
        } else {
            Write-Host ("    schtasks failed (exit {0}): {1}" -f $create.Code, ($create.Output -join ' ')) -ForegroundColor Yellow
        }
    }

    Ensure-FirewallRule

    if (-not $installed) {
        Write-Host ''
        Write-Host '  Could not register the startup task on this machine.' -ForegroundColor Yellow
        Write-Host '  The listener was NOT started. Two ways forward:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    A) run it in the background once (survives closing this window, not a reboot):'
        Write-Host ('         powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -StartHidden' -f $scriptPath)
        Write-Host '       then register autostart at logon as a fallback:'
        Write-Host ('         powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -RegisterAutostart' -f $scriptPath)
        Write-Host ''
        Write-Host '    B) fix task creation: run -Diagnose and look at Schedule / KtmRm,'
        Write-Host '       then retry -Install. (schtasks writes task files through TxF,'
        Write-Host '       which needs the KtmRm service.)'
        Write-Host ''
        return 1
    }

    Start-Sleep -Seconds 2
    Write-Host ''
    Write-Host ('  Receiver installed via {0}.' -f $how) -ForegroundColor Green
    Write-Host ("    task      : {0} (SYSTEM, at startup)" -f $TaskName)
    Write-Host ("    port      : TCP {0} (Windows firewall rule added)" -f $Port)
    if ($targetList.Count -gt 0) {
        foreach ($t in $targetList) {
            $httpsNote = '  [no https binding - the threads build needs a secure context]'
            if ($t.HasHttps) { $httpsNote = '  [https]' }
            Write-Host ("    target    : {0}  ({1}){2}" -f $t.Target, $t.Site, $httpsNote)
        }
    } else {
        Write-Host '    target    : <unresolved - check IIS>'
    }
    Write-Host ("    state dir : {0}" -f $StateDir)
    Write-Host ("    token     : {0}" -f $script:Token) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Open the same TCP port in the cloud security group, then on the workstation:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('    python tools\deploy_cloud.py --init')
    Write-Host ('      host  = <server public IP>')
    Write-Host ('      port  = {0}' -f $Port)
    Write-Host ('      token = {0}' -f $script:Token)
    Write-Host ''
    Write-Host '  Check it from the workstation with:  python tools\deploy_cloud.py --health'
    Write-Host ''
    return 0
}

function Start-HiddenReceiver {
    [void](Save-Token)
    Ensure-FirewallRule
    $pidPath = Join-Path $StateDir 'receiver.pid'
    if (Test-Path -LiteralPath $pidPath) {
        $old = (Get-Content -LiteralPath $pidPath -Raw).Trim()
        if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
            Write-Host ("  already running (pid {0}); use -Stop first" -f $old) -ForegroundColor Yellow
            return 1
        }
    }
    $arguments = Get-ChildArguments
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidPath -Value $proc.Id -Encoding ASCII
    Start-Sleep -Seconds 2
    Write-Host ("  receiver started hidden, pid {0}" -f $proc.Id) -ForegroundColor Green
    Write-Host ("  pid file: {0}" -f $pidPath)
    Write-Host '  this does not survive a reboot - see -RegisterAutostart or -Install'
    return 0
}

function Stop-Receiver {
    $pidPath = Join-Path $StateDir 'receiver.pid'
    $stopped = 0
    if (Test-Path -LiteralPath $pidPath) {
        $procId = (Get-Content -LiteralPath $pidPath -Raw).Trim()
        if ($procId) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { Stop-Process -Id $procId -Force; $stopped++ }
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
    # Only listener processes: they carry -Foreground (see Get-ChildArguments).
    # Matching on the script name alone would also match the console that ran
    # -Stop, and each other shell whose command line mentions the script.
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                     Where-Object {
                         $_.ProcessId -ne $PID -and $_.CommandLine -and
                         $_.CommandLine -match 'pk_web_receiver\.ps1' -and
                         $_.CommandLine -match '-Foreground'
                     })) {
        try { Stop-Process -Id $p.ProcessId -Force; $stopped++ } catch { }
    }
    Write-Host ("  stopped {0} receiver process(es)" -f $stopped) -ForegroundColor Green
    return 0
}

function Set-Autostart {
    # Fallback for machines where task creation is broken: HKLM Run key.
    # Runs at logon of any user, not at boot.
    [void](Save-Token)
    Ensure-FirewallRule
    $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    $value = 'powershell.exe ' + (Get-ChildArguments)
    New-ItemProperty -Path $key -Name $TaskName -Value $value -PropertyType String -Force | Out-Null
    Write-Host ("  autostart registered ({0}\{1}); runs when a user logs on" -f $key, $TaskName) -ForegroundColor Green
    return 0
}

function Remove-Autostart {
    $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty -Path $key -Name $TaskName -Force -ErrorAction SilentlyContinue
    Write-Host '  autostart removed' -ForegroundColor Green
    return 0
}

function Show-Diagnostics {
    Write-Host ''
    Write-Host '  Diagnostics' -ForegroundColor Cyan
    Write-Host ("    PowerShell   : {0}" -f $PSVersionTable.PSVersion)
    Write-Host ("    OS           : {0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)
    $admin = $false
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    Write-Host ("    elevated     : {0}" -f $admin)
    foreach ($name in @('Schedule', 'KtmRm', 'MSDTC')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { Write-Host ("    service {0,-6}: {1} / {2}" -f $name, $svc.Status, (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name)).StartMode) }
        else { Write-Host ("    service {0,-6}: not present" -f $name) }
    }
    $tasks = Join-Path $env:windir 'System32\Tasks'
    try {
        $fs = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f (Split-Path $tasks -Qualifier))
        Write-Host ("    tasks dir    : {0} ({1})" -f $tasks, $fs.FileSystem)
    } catch { Write-Host ("    tasks dir    : {0}" -f $tasks) }
    if ($NoProbe) {
        Write-Host '    schtasks     : probe skipped (-NoProbe)'
    } else {
        $result = Invoke-Native 'schtasks.exe' @('/create', '/tn', ($TaskName + 'Probe'), '/tr', 'cmd /c exit 0', '/sc', 'once', '/st', '23:59', '/f')
        Write-Host ("    schtasks     : exit {0} {1}" -f $result.Code, ($result.Output -join ' '))
        if ($result.Code -eq 0) { [void](Invoke-Native 'schtasks.exe' @('/delete', '/tn', ($TaskName + 'Probe'), '/f')) }
    }
    try {
        $scheduledTasks = Get-Module -ListAvailable -Name ScheduledTasks
        Write-Host ("    module       : {0}" -f $(if ($scheduledTasks) { 'ScheduledTasks available' } else { 'ScheduledTasks MISSING' }))
    } catch { }
    Write-Host ("    script       : {0}" -f $script:ScriptPath)
    try {
        foreach ($t in @(Resolve-TargetRoots)) { Write-Host ("    target       : {0}  ({1})" -f $t.Target, $t.Site) }
    } catch {
        Write-Host ("    target       : {0}" -f $_.Exception.Message)
    }
    Write-Host ''
    return 0
}

function Uninstall-Receiver {
    [void](Invoke-Native 'schtasks.exe' @('/delete', '/tn', $TaskName, '/f'))
    [void](Invoke-Native 'netsh.exe' @('advfirewall', 'firewall', 'delete', 'rule', "name=$FirewallRule"))
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $TaskName + '*') } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    if (Test-Path -LiteralPath (Join-Path $StateDir 'sessions')) {
        Remove-Item -LiteralPath (Join-Path $StateDir 'sessions') -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '  Receiver uninstalled (task + firewall rule removed, token kept).' -ForegroundColor Green
}

function Show-Status {
    Write-Host ''
    Write-Host '  PK web receiver status' -ForegroundColor Cyan
    $task = Invoke-Native 'schtasks.exe' @('/query', '/tn', $TaskName, '/fo', 'LIST')
    if ($task.Code -eq 0) {
        $line = $task.Output | Where-Object { $_ -match 'Status' } | Select-Object -First 1
        Write-Host ("    task      : {0}" -f $(if ($line) { $line.Trim() } else { $TaskName }))
    } else {
        Write-Host '    task      : not installed'
    }
    $listen = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($listen.Count -gt 0) { Write-Host ("    listening : TCP {0} (pid {1})" -f $Port, $listen[0].OwningProcess) }
    else { Write-Host ("    listening : nothing on TCP {0}" -f $Port) }
    try {
        foreach ($t in @(Resolve-TargetRoots)) {
            Write-Host ("    target    : {0}  ({1}){2}" -f $t.Target, $t.Site, $(if ($t.HasHttps) { '  [https]' } else { '  [http only]' }))
        }
    } catch {
        Write-Host ("    target    : unresolved ({0})" -f $_.Exception.Message)
    }
    $fw = Invoke-Native 'netsh.exe' @('advfirewall', 'firewall', 'show', 'rule', "name=$FirewallRule")
    if ($fw.Code -eq 0) {
        Write-Host ("    firewall  : inbound rule '{0}' present" -f $FirewallRule)
    } else {
        Write-Host ("    firewall  : NO inbound rule for TCP {0} - --health from the workstation will time out" -f $Port) -ForegroundColor Yellow
    }
    $tokenPath = Join-Path $StateDir 'token.txt'
    if (Test-Path -LiteralPath $tokenPath) { Write-Host ("    token     : {0}" -f (Get-Content -LiteralPath $tokenPath -Raw).Trim()) }
    Write-Host ("    log       : {0}" -f $script:LogPath)
    Write-Host ''
}

# -------------------------------------------------------------------- main ---
function Show-Usage {
    Write-Host ''
    Write-Host '  pk_web_receiver.ps1 - HTTP receiver for one-click web package deploys' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    -Install              register + start the receiver (SYSTEM, at startup),'
    Write-Host '                          add the firewall rule, print the token'
    Write-Host '    -Status               task, listening port, resolved IIS directory, token'
    Write-Host '    -Diagnose             PowerShell/OS/services/schtasks/scheduled-task module'
    Write-Host '    -StartHidden          run the listener in a hidden process now (no reboot survival)'
    Write-Host '    -Stop                 stop receiver processes'
    Write-Host '    -RegisterAutostart    HKLM Run key fallback (starts at user logon)'
    Write-Host '    -UnregisterAutostart  remove that Run key'
    Write-Host '    -Uninstall            remove task + firewall rule + autostart + sessions'
    Write-Host '    -Foreground           run in this console (no task); for testing'
    Write-Host ''
    Write-Host '  Common options: -Port 8099 -AppName web-debug [-Token <hex>] [-TargetRoot <dir>]'
    Write-Host ''
    return 1
}

if (-not $script:Token) {
    $maybe = Join-Path $StateDir 'token.txt'
    if (Test-Path -LiteralPath $maybe) { $script:Token = (Get-Content -LiteralPath $maybe -Raw).Trim() }
}

if ($Uninstall) { Uninstall-Receiver; exit 0 }
if ($Status) { Show-Status; exit 0 }
if ($Diagnose) { exit (Show-Diagnostics) }
if ($Stop) { exit (Stop-Receiver) }
if ($RegisterAutostart) { exit (Set-Autostart) }
if ($UnregisterAutostart) { exit (Remove-Autostart) }
if ($StartHidden) { exit (Start-HiddenReceiver) }
if ($Install) { exit (Install-Receiver) }
if ($Foreground) {
    if (-not $Token) { throw 'no token: pass -Token <hex> (or run -Install first)' }
    Start-Receiver
    exit 0
}

# No mode given: never guess (an accidental -Install on a production box is not
# something the caller should discover afterwards).
exit (Show-Usage)
