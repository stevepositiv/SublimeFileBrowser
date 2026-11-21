<#
.SYNOPSIS
    Initialise (or prepare) a Git repository on Windows whose tree contains junctions.

.DESCRIPTION
    Git for Windows follows directory junctions as if they were normal folders, but it
    does not follow directory symlinks (it stores those as links). This script walks
    the tree the way Git will see it and, before you `git add`, writes .gitignore
    entries for:

      * embedded Git repositories (any folder containing a .git dir or file), so Git
        doesn't record them as accidental gitlinks;
      * circular junctions: the folder that contains the junction is excluded
        entirely. If the junction sits directly in the repo root, only the junction
        itself is excluded.

    Junctions are followed. A junction counts as circular when its fully resolved
    target is the same as, or contains, one of the folders on the current path
    (this also catches loops that go through several junctions). Two junctions to
    the same place are not a loop; Git follows both, so both are scanned.

    Folders already excluded by existing ignore rules are not scanned. Registered
    submodules (.gitmodules) are left alone. Gitlinks already in the index that are
    not submodules are removed from the index (files on disk are untouched).

.PARAMETER Path
    Folder to initialise and scan. Defaults to the current directory.

.EXAMPLE
    git-init-win
.EXAMPLE
    git-init-win D:\scratch\weird-repo -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$Path = '.'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$gitExe = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gitExe) { throw 'git was not found in PATH.' }
$gitExe = $gitExe.Source

$rootItem = Get-Item -LiteralPath $Path -Force
if (-not $rootItem.PSIsContainer) { throw "Not a folder: $Path" }
$root = $rootItem.FullName
if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }

# --- Native helper: fully resolved path (every junction/symlink in every component) ---
if (-not ('GitInitWin.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace GitInitWin {
    public static class Native {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
            StringBuilder buffer, uint size, uint flags);

        // Returns null if the path can't be opened (broken link, access denied, ...).
        public static string GetFinalPath(string path) {
            // access 0, share read|write|delete, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS (needed for dirs)
            using (SafeFileHandle h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (h.IsInvalid) return null;
                StringBuilder sb = new StringBuilder(512);
                uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                if (n >= sb.Capacity) {
                    sb = new StringBuilder((int)n + 1);
                    n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                }
                if (n == 0 || n >= sb.Capacity) return null;
                string s = sb.ToString();
                if (s.StartsWith(@"\\?\UNC\")) return @"\\" + s.Substring(8);
                if (s.StartsWith(@"\\?\")) return s.Substring(4);
                return s;
            }
        }
    }
}
'@
}

# --- Path helpers ------------------------------------------------------------------
function Get-IoPath([string]$p) {
    # Long-path prefix so deep trees work on Windows PowerShell 5.1 too.
    if ($p.Length -lt 240 -or $p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
    return '\\?\' + $p
}

function Join-Real([string]$parent, [string]$name) {
    if ($parent.EndsWith('\')) { return "$parent$name" }
    return "$parent\$name"
}

function Test-IsSameOrInside([string]$path, [string]$container) {
    $p = $path.TrimEnd('\') + '\'
    $c = $container.TrimEnd('\') + '\'
    return $p.StartsWith($c, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-IgnorePattern([string]$rel) {
    # Anchored to the repo root, glob characters escaped, trailing / = directory only.
    return '/' + ($rel -replace '([\\\[\]*?])', '\$1') + '/'
}

# --- Long-running `git check-ignore` so existing ignore rules prune the scan ----------
$checker = $null
$utf8 = New-Object System.Text.UTF8Encoding $false

function Start-IgnoreChecker {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $gitExe
    $psi.Arguments = 'check-ignore --stdin -z -v --non-matching'
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.EnvironmentVariables['GIT_FLUSH'] = '1'
    return [System.Diagnostics.Process]::Start($psi)
}

function Test-Ignored([string]$rel) {
    if (-not $checker) { return $false }
    $bytes = $utf8.GetBytes($rel + "`0")
    $checker.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $checker.StandardInput.BaseStream.Flush()
    # -z -v --non-matching: <source> NUL <line> NUL <pattern> NUL <path> NUL
    $fields = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    while ($fields.Count -lt 4) {
        $c = $checker.StandardOutput.Read()
        if ($c -lt 0) { throw "git check-ignore exited unexpectedly while checking '$rel'." }
        if ($c -eq 0) { $fields.Add($sb.ToString()); [void]$sb.Clear() }
        else { [void]$sb.Append([char]$c) }
    }
    # Matched by a negated pattern (!foo) means NOT ignored.
    return ($fields[0] -ne '' -and -not $fields[2].StartsWith('!'))
}

# --- .gitignore bookkeeping -----------------------------------------------------------
$gitignorePath = Join-Path $root '.gitignore'
$ignoreText = ''
$ignoreNeedsRewrite = $false
if (Test-Path -LiteralPath $gitignorePath) {
    $reader = New-Object System.IO.StreamReader($gitignorePath, $utf8, $true)
    try {
        $ignoreText = $reader.ReadToEnd()
        if ($reader.CurrentEncoding.WebName -ne 'utf-8') {
            Write-Warning ".gitignore is $($reader.CurrentEncoding.WebName); Git can't read that. It will be rewritten as UTF-8."
            $ignoreNeedsRewrite = $true
        }
    } finally { $reader.Dispose() }
}
$knownPatterns = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($line in ($ignoreText -split '\r?\n')) { [void]$knownPatterns.Add($line.Trim()) }
$newLines = New-Object System.Collections.Generic.List[string]
$stats = @{ Scanned = 0; Pruned = 0; Repos = 0; Loops = 0 }

function Add-IgnoreEntry([string]$rel, [string]$why) {
    $pattern = ConvertTo-IgnorePattern $rel
    if (-not $knownPatterns.Add($pattern)) { return }
    $newLines.Add("# $why")
    $newLines.Add($pattern)
    Write-Host "  ignore $pattern  ($why)" -ForegroundColor Green
}

$prevOutputEncoding = $null
try { $prevOutputEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = $utf8 } catch { }

try {
    # 1. git init ------------------------------------------------------------------------
    $hasRepo = Test-Path -LiteralPath (Join-Path $root '.git')
    if (-not $hasRepo) {
        if ($PSCmdlet.ShouldProcess($root, 'git init')) {
            & $gitExe -C $root init
            if ($LASTEXITCODE) { throw 'git init failed.' }
            $hasRepo = $true
        } else {
            Write-Warning 'No repository yet: existing ignore rules will not be consulted in this dry run.'
        }
    }

    # 2. Submodules stay; other staged gitlinks get untracked ---------------------------
    $submodules = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($hasRepo) {
        $gitmodules = Join-Path $root '.gitmodules'
        if (Test-Path -LiteralPath $gitmodules) {
            $raw = (& $gitExe -C $root config -z -f $gitmodules --get-regexp '^submodule\..*\.path$') -join "`n"
            foreach ($rec in ($raw -split "`0")) {
                $i = $rec.IndexOf("`n")
                if ($i -ge 0) { [void]$submodules.Add($rec.Substring($i + 1)) }
            }
        }

        $staged = (& $gitExe -C $root ls-files -z --stage) -join "`n"
        foreach ($rec in ($staged -split "`0")) {
            if ($rec -notmatch '^160000 ') { continue }
            $p = $rec.Substring($rec.IndexOf("`t") + 1)
            if ($submodules.Contains($p)) { continue }
            if ($PSCmdlet.ShouldProcess($p, 'git rm --cached (embedded repo staged as gitlink)')) {
                & $gitExe --literal-pathspecs -C $root rm --cached -f -q -- $p
                if ($LASTEXITCODE) { Write-Warning "Could not untrack '$p'." }
                else { Write-Host "  untracked gitlink $p" -ForegroundColor Yellow }
            }
        }
        $checker = Start-IgnoreChecker
    }

    # 3. Walk the tree the way Git sees it -----------------------------------------------
    Write-Host "Scanning $root ..." -ForegroundColor Cyan
    $rootReal = [GitInitWin.Native]::GetFinalPath((Get-IoPath $root))
    if (-not $rootReal) { $rootReal = $root }

    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ Rel = ''; Real = $rootReal; Chain = @() })

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $isRoot = $node.Rel -eq ''

        if (-not $isRoot) {
            if ($submodules.Contains($node.Rel)) { continue }
            if (Test-Ignored $node.Rel) { $stats.Pruned++; continue }
            $dotGit = Get-IoPath (Join-Real $node.Real '.git')
            if ([IO.Directory]::Exists($dotGit) -or [IO.File]::Exists($dotGit)) {
                $stats.Repos++
                Add-IgnoreEntry $node.Rel 'embedded git repository'
                continue
            }
        }

        $stats.Scanned++
        try {
            $children = @((New-Object System.IO.DirectoryInfo (Get-IoPath $node.Real)).GetDirectories())
        } catch {
            Write-Warning "Cannot read '$(if ($isRoot) { '.' } else { $node.Rel })': $($_.Exception.Message)"
            continue
        }

        $chain = $node.Chain + $node.Real    # real paths of every folder from root to here
        $toPush = New-Object System.Collections.Generic.List[object]
        $loops = New-Object System.Collections.Generic.List[string]

        foreach ($child in $children) {
            $name = $child.Name
            if ($isRoot -and $name -eq '.git') { continue }
            $rel = if ($isRoot) { $name } else { "$($node.Rel)/$name" }
            $real = Join-Real $node.Real $name

            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $linkType = $child.LinkType
                # Git stores directory symlinks as links and never descends into them.
                if ($linkType -eq 'SymbolicLink') { continue }
                if ($linkType -eq 'Junction') {
                    $target = [GitInitWin.Native]::GetFinalPath((Get-IoPath $real))
                    if (-not $target) { Write-Warning "Skipping unresolvable junction '$rel'."; continue }

                    $isLoop = $false
                    foreach ($a in $chain) {
                        if (Test-IsSameOrInside $a $target) { $isLoop = $true; break }
                    }
                    if ($isLoop) {
                        if (Test-Ignored $rel) { continue }   # existing rule already handles it
                        $stats.Loops++
                        Write-Warning "Circular junction: '$rel' -> '$target'"
                        if ($isRoot) { Add-IgnoreEntry $rel "circular junction -> $target" }
                        else { $loops.Add("$name -> $target") }
                        continue
                    }
                    $real = $target
                }
                # Other reparse points (OneDrive placeholders etc.) are ordinary folders to Git.
            }
            $toPush.Add([pscustomobject]@{ Rel = $rel; Real = $real; Chain = $chain })
        }

        if ($loops.Count -gt 0) {
            # Exclude the folder holding the junction entirely; don't descend into it.
            Add-IgnoreEntry $node.Rel ('contains circular junction ' + ($loops -join '; '))
            continue
        }
        for ($i = $toPush.Count - 1; $i -ge 0; $i--) { $stack.Push($toPush[$i]) }
    }

    # 4. Write .gitignore ----------------------------------------------------------------
    $entryCount = ($newLines.Count / 2)
    if ($entryCount -gt 0 -or $ignoreNeedsRewrite) {
        $nl = if ($ignoreText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $block = New-Object System.Text.StringBuilder
        if ($ignoreText.Length -gt 0 -and -not $ignoreText.EndsWith("`n")) { [void]$block.Append($nl) }
        if ($entryCount -gt 0) {
            if ($ignoreText.Trim().Length -gt 0) { [void]$block.Append($nl) }
            [void]$block.Append("# --- added by git-init-win $(Get-Date -Format yyyy-MM-dd) ---$nl")
            foreach ($l in $newLines) { [void]$block.Append($l + $nl) }
        }
        if ($PSCmdlet.ShouldProcess($gitignorePath, "add $entryCount entr$(if ($entryCount -eq 1) { 'y' } else { 'ies' })")) {
            if ($ignoreNeedsRewrite) {
                [IO.File]::WriteAllText($gitignorePath, $ignoreText + $block.ToString(), $utf8)
            } else {
                [IO.File]::AppendAllText($gitignorePath, $block.ToString(), $utf8)
            }
        }
    }

    Write-Host ("Done. Scanned {0} folders, skipped {1} already ignored, found {2} embedded repos and {3} circular junctions." -f `
        $stats.Scanned, $stats.Pruned, $stats.Repos, $stats.Loops) -ForegroundColor Cyan
    if ($entryCount -gt 0) { Write-Host 'Review .gitignore, then check with: git add -A --dry-run' -ForegroundColor Cyan }
}
finally {
    if ($checker) {
        try { $checker.StandardInput.Close(); [void]$checker.WaitForExit(3000) } catch { }
        $checker.Dispose()
    }
    if ($prevOutputEncoding) { try { [Console]::OutputEncoding = $prevOutputEncoding } catch { } }
}
