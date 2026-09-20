<#
.SYNOPSIS
    Cut a GuildLedger release.

.DESCRIPTION
    Bumps the version in GuildLedger.toc, commits it, tags it, and pushes.
    The push of the tag is what kicks off .github/workflows/release.yml,
    which builds the zip and publishes it as a GitHub release.

.EXAMPLE
    .\release.ps1 0.2.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    # Release from a branch other than main. Normally you don't want this.
    [switch] $AllowAnyBranch
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$toc = Join-Path $PSScriptRoot 'GuildLedger.toc'
$tag = "v$Version"

# --- sanity checks ------------------------------------------------------

if (git status --porcelain) {
    throw "Working tree isn't clean. Commit or stash first, then re-run."
}

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main' -and -not $AllowAnyBranch) {
    throw "On branch '$branch', not 'main'. Merge to main first, or pass -AllowAnyBranch."
}

if (git tag --list $tag) {
    throw "Tag $tag already exists. Pick a new version number."
}

# --- bump the .toc ------------------------------------------------------

$content = Get-Content -LiteralPath $toc -Raw
$bumped = [regex]::Replace($content, '(?m)^## Version:.*$', "## Version: $Version")
if ($bumped -eq $content) {
    throw "Couldn't find a '## Version:' line in GuildLedger.toc."
}
# Deliberately not Set-Content -Encoding utf8: on Windows PowerShell 5.1
# that writes a BOM, and a BOM ahead of '## Interface:' stops WoW from
# reading the .toc header.
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($toc, $bumped, $utf8NoBom)

# --- commit, tag, push --------------------------------------------------

git add -- GuildLedger.toc
git commit -m "Release $tag"
if (-not $?) { throw 'git commit failed.' }

git tag -a $tag -m "GuildLedger $Version"
if (-not $?) { throw 'git tag failed.' }

git push origin $branch
if (-not $?) { throw 'git push failed.' }

git push origin $tag
if (-not $?) { throw 'git push --tags failed.' }

$remote = (git remote get-url origin).Trim() -replace '\.git$', ''
Write-Host ''
Write-Host "Pushed $tag. GitHub Actions is building the zip now:" -ForegroundColor Green
Write-Host "  $remote/actions"
Write-Host "It'll show up here in a minute or two:" -ForegroundColor Green
Write-Host "  $remote/releases/tag/$tag"
