<#
.SYNOPSIS
    Stow all packages in your dotfiles directory.

.DESCRIPTION
    Automatically stows all subdirectories in your dotfiles directory using zstow.
    Supports the same flags as zstow for stowing, unstowing, and dry-run operations.

.PARAMETER DotfilesDir
    Path to dotfiles directory. Default: $HOME\dotfiles

.PARAMETER TargetDir
    Target directory for stowing. Default: parent of dotfiles directory

.PARAMETER Delete
    Unstow all packages instead of stowing them.

.PARAMETER Restow
    Restow all packages (unstow then stow).

.PARAMETER DryRun
    Show what would be done without actually doing it.

.EXAMPLE
    .\stow-all.ps1
    Stows all packages from $HOME\dotfiles

.EXAMPLE
    .\stow-all.ps1 -Delete
    Unstows all packages

.EXAMPLE
    .\stow-all.ps1 -DryRun -Verbose
    Shows what would be stowed with verbose output

.EXAMPLE
    .\stow-all.ps1 -DotfilesDir C:\my-dotfiles -TargetDir $HOME
    Stows from custom directory to home directory
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DotfilesDir = "$HOME\dotfiles",
    
    [Parameter()]
    [string]$TargetDir = "",
    
    [Parameter()]
    [switch]$Delete,
    
    [Parameter()]
    [switch]$Restow,
    
    [Parameter()]
    [switch]$DryRun,
    
    [Parameter()]
    [string]$StowCommand = "zstow"
)

# Use environment variable if set
if ($env:DOTFILES_DIR) {
    $DotfilesDir = $env:DOTFILES_DIR
}
if ($env:STOW_CMD) {
    $StowCommand = $env:STOW_CMD
}

# Verify dotfiles directory exists
if (-not (Test-Path -Path $DotfilesDir -PathType Container)) {
    Write-Host "Error: Dotfiles directory not found: $DotfilesDir" -ForegroundColor Red
    exit 1
}

# Resolve to absolute path
$DotfilesDir = Resolve-Path $DotfilesDir

# Find all package directories
$excludeDirs = @('scripts', 'bin', 'docs', '.git', '.gitignore')

$packages = Get-ChildItem -Path $DotfilesDir -Directory -Force | Where-Object {
    $name = $_.Name
    
    if ($name -eq '.' -or $name -eq '..') {
        return $false
    }
    
    if ($excludeDirs -contains $name) {
        return $false
    }
    
    if ($name -match '^(README|LICENSE)') {
        return $false
    }
    
    return $true
} | Select-Object -ExpandProperty Name

# Check if any packages found
if ($packages.Count -eq 0) {
    Write-Host "No packages found in $DotfilesDir" -ForegroundColor Yellow
    exit 0
}

# Build stow arguments
$stowArgs = @()

if ($TargetDir) {
    $stowArgs += "-t", $TargetDir
}

if ($Delete) {
    $stowArgs += "-D"
} elseif ($Restow) {
    $stowArgs += "-R"
}

if ($DryRun) {
    $stowArgs += "-n"
}

# Check for -Verbose using the automatic common parameter from [CmdletBinding()]
if ($PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) {
    $stowArgs += "-v"
}

# Add all packages
$stowArgs += $packages

# Show what we're about to do
Write-Host "Dotfiles directory: $DotfilesDir" -ForegroundColor Cyan
Write-Host "Found $($packages.Count) package(s): $($packages -join ', ')" -ForegroundColor Cyan
Write-Host "Command: $StowCommand $($stowArgs -join ' ')" -ForegroundColor Cyan
Write-Host ""

# Change to dotfiles directory
Push-Location $DotfilesDir

try {
    & $StowCommand @stowArgs
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "Done!" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Stow command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }
} catch {
    Write-Host "Error executing stow command: $_" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
