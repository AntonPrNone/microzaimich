param(
    [string]$RepositoryName = "microzaimich",
    [string]$PublishBranch = "gh-pages",
    [switch]$Push
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$buildDir = Join-Path $repoRoot "build\web"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("microzaimich-gh-pages-" + [guid]::NewGuid().ToString("N"))

Write-Host "Building Flutter web for GitHub Pages..."
Push-Location $repoRoot
try {
    flutter build web --release --base-href "/$RepositoryName/"

    if (-not (Test-Path $buildDir)) {
        throw "Flutter web build directory not found: $buildDir"
    }

    Copy-Item (Join-Path $buildDir "index.html") (Join-Path $buildDir "404.html") -Force

    Write-Host "Preparing temporary worktree for branch $PublishBranch..."
    git worktree add --force $tempDir $PublishBranch 2>$null
} catch {
    if ($_.Exception.Message -match "invalid reference|unknown revision|not a commit") {
        git worktree add --orphan $tempDir $PublishBranch
    } else {
        throw
    }
}

try {
    Push-Location $tempDir
    try {
        Get-ChildItem -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
        Copy-Item (Join-Path $buildDir "*") $tempDir -Recurse -Force

        git add .
        $status = git status --short
        if (-not $status) {
            Write-Host "No changes to publish."
        } else {
            git commit -m "Deploy Flutter web"
            if ($Push) {
                git push origin $PublishBranch
                Write-Host "Published to origin/$PublishBranch"
            } else {
                Write-Host "Commit created locally on $PublishBranch. Re-run with -Push to publish."
            }
        }
    } finally {
        Pop-Location
    }
} finally {
    Push-Location $repoRoot
    try {
        git worktree remove $tempDir --force
    } finally {
        Pop-Location
    }
}
