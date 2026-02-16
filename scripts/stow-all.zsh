#!/usr/bin/env zsh
# stow-all.zsh - Stow all packages in the dotfiles directory

set -e

# Configuration
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
STOW_CMD="${STOW_CMD:-zstow}"

# Colors for output
autoload -U colors && colors

print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Stow all packages in your dotfiles directory.

OPTIONS:
    -d, --dir DIR       Dotfiles directory (default: ~/dotfiles)
    -t, --target DIR    Target directory (default: parent of dotfiles dir)
    -D, --delete        Unstow all packages instead of stowing
    -R, --restow        Restow all packages
    -n, --dry-run       Show what would be done without doing it
    -v, --verbose       Verbose output
    -h, --help          Show this help

EXAMPLES:
    $(basename "$0")                    # Stow all packages
    $(basename "$0") -D                 # Unstow all packages
    $(basename "$0") -nv                # Dry-run with verbose output
    $(basename "$0") -d ~/my-dotfiles   # Use custom dotfiles directory

ENVIRONMENT:
    DOTFILES_DIR    Override default dotfiles directory
    STOW_CMD        Override stow command (default: zstow)
EOF
}

# Parse arguments
STOW_ARGS=()
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dir)
            DOTFILES_DIR="$2"
            shift 2
            ;;
        -t|--target)
            TARGET_DIR="$2"
            shift 2
            ;;
        -D|--delete|-R|--restow|-n|--dry-run|-v|--verbose)
            STOW_ARGS+=("$1")
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "${fg[red]}Error: Unknown option: $1${reset_color}" >&2
            print_usage
            exit 1
            ;;
    esac
done

# Verify dotfiles directory exists
if [[ ! -d "$DOTFILES_DIR" ]]; then
    echo "${fg[red]}Error: Dotfiles directory not found: $DOTFILES_DIR${reset_color}" >&2
    exit 1
fi

# Change to dotfiles directory
cd "$DOTFILES_DIR" || exit 1

# Find all directories (packages)
# Exclude only specific directories that shouldn't be stowed
EXCLUDE_DIRS=(scripts bin docs .git)

packages=()

# Find all directories (both regular and hidden) using a more robust method
while IFS= read -r dir; do
    [[ ! -d "$dir" ]] && continue
    
    pkg=$(basename "$dir")
    
    # Skip . and ..
    [[ "$pkg" == "." || "$pkg" == ".." ]] && continue
    
    # Skip excluded directories
    [[ " ${EXCLUDE_DIRS[@]} " =~ " ${pkg} " ]] && continue
    
    # Skip README and LICENSE files/dirs
    [[ "$pkg" =~ ^(README|LICENSE) ]] && continue
    
    packages+=("$pkg")
done < <(find . -maxdepth 1 -type d)

# Check if any packages found
if [[ ${#packages[@]} -eq 0 ]]; then
    echo "${fg[yellow]}No packages found in $DOTFILES_DIR${reset_color}"
    exit 0
fi

# Build stow command
stow_cmd=("$STOW_CMD")
[[ -n "$TARGET_DIR" ]] && stow_cmd+=(-t "$TARGET_DIR")
stow_cmd+=("${STOW_ARGS[@]}")

# Show what we're about to do
echo "${fg[blue]}Dotfiles directory: $DOTFILES_DIR${reset_color}"
echo "${fg[blue]}Found ${#packages[@]} package(s): ${packages[*]}${reset_color}"
echo "${fg[blue]}Command: ${stow_cmd[*]} ${packages[*]}${reset_color}"
echo ""

# Execute stow for all packages
"${stow_cmd[@]}" "${packages[@]}"

echo ""
echo "${fg[green]}✓ Done!${reset_color}"
