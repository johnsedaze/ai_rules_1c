#!/bin/bash
#
# .SYNOPSIS
#     Refreshes content/openspec-bundle/ from a locally installed OpenSpec CLI.
#
# .DESCRIPTION
#     Maintainer-only utility. Runs `openspec init` in a temporary directory
#     against the five tools supported by 1c-rules, then mirrors the resulting
#     files into content/openspec-bundle/<tool>/ and refreshes
#     content/openspec-bundle/version.txt with the CLI's reported version.
#
#     Bumps the static snapshot that the installer ships, so end-users continue
#     to get OpenSpec slash commands and SKILLs without needing npm at install
#     time. Re-run after upgrading the OpenSpec CLI.
#
#     Requirements (maintainer machine only):
#       - Node.js + npm
#       - The official OpenSpec CLI installed globally:
#           npm install -g @fission-ai/openspec@latest
#
# .PARAMETER RepoRoot
#     Path to the 1c-rules source repository. Defaults to the parent directory
#     of the script (i.e. running from the repo works without arguments).
#
# .PARAMETER DryRun
#     Show planned actions and the diff summary; do not modify the repository.
#
# .EXAMPLE
#     ./tools/refresh-openspec-bundle.sh
#
# .EXAMPLE
#     ./tools/refresh-openspec-bundle.sh -dry-run
#

set -euo pipefail

TOOLS=("cursor" "claude-code" "codex" "opencode" "kilocode")
OPENSPEC_TOOLS_ARG="cursor,claude,codex,opencode,kilocode"

# Dot directories mapping - using case statement instead of associative array for compatibility
get_dot_dir() {
    local tool="$1"
    case "$tool" in
        cursor)      echo ".cursor" ;;
        claude-code) echo ".claude" ;;
        codex)       echo ".codex" ;;
        opencode)    echo ".opencode" ;;
        kilocode)    echo ".kilo" ;;
        *)           echo "" ;;
    esac
}

REPO_ROOT=""
DRY_RUN=false

function usage() {
    echo "Usage: $0 [-h|--help] [--dry-run] [<repo-root>]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --dry-run      Show planned actions without modifying files"
    echo ""
    echo "Arguments:"
    echo "  <repo-root>    Path to the 1c-rules source repository (default: parent of script)"
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                if [[ -z "$REPO_ROOT" ]]; then
                    REPO_ROOT="$1"
                    shift
                else
                    echo "Error: Multiple repo root arguments provided" >&2
                    usage >&2
                    exit 1
                fi
                ;;
        esac
    done
}

function resolve_repo_root() {
    if [[ -n "$REPO_ROOT" ]]; then
        if [[ ! -d "$REPO_ROOT" ]]; then
            echo "Error: RepoRoot does not exist: $REPO_ROOT" >&2
            exit 1
        fi
        echo "$(cd "$REPO_ROOT" && pwd)"
        return
    fi
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(cd "$script_dir/.." && pwd)"
}

function test_openspec_available() {
    if ! command -v openspec &> /dev/null; then
        echo "Error: OpenSpec CLI not found on PATH." >&2
        echo "Install it first: npm install -g @fission-ai/openspec@latest" >&2
        exit 1
    fi
    
    local version
    version=$(openspec --version 2>/dev/null || true)
    if [[ -z "$version" ]]; then
        echo "Error: openspec --version returned empty output" >&2
        exit 1
    fi
    
    echo "$version"
}

function invoke_openspec_init() {
    local work_dir="$1"
    local output
    local exit_code
    
    pushd "$work_dir" > /dev/null
    set +e
    output=$(openspec init --tools "$OPENSPEC_TOOLS_ARG" 2>&1)
    exit_code=$?
    set -e
    popd > /dev/null
    
    if [[ $exit_code -ne 0 ]]; then
        echo "$output" >&2
        echo "Error: openspec init failed (exit $exit_code)" >&2
        exit 1
    fi
    
    echo "$output"
}

function get_relative_files() {
    local base_dir="$1"
    if [[ ! -d "$base_dir" ]]; then
        return
    fi
    
    local base_path
    base_path="$(cd "$base_dir" && pwd)"
    
    find "$base_path" -type f | while read -r file; do
        echo "${file#$base_path/}"
    done | sort
}

function sync_tool_bundle() {
    local tool="$1"
    local probe_root="$2"
    local bundle_root="$3"
    local dry_run="$4"
    
    local dot="$(get_dot_dir "$tool")"
    local source_dir="$probe_root/$dot"
    
    # For kilocode: if .kilo doesn't exist, try .kilocode (legacy path)
    if [[ "$tool" == "kilocode" && ! -d "$source_dir" ]]; then
        local alt_source_dir="$probe_root/.kilocode"
        if [[ -d "$alt_source_dir" ]]; then
            source_dir="$alt_source_dir"
        fi
    fi
    
    local target_dir="$bundle_root/$tool/$dot"
    
    if [[ ! -d "$source_dir" ]]; then
        echo "  Warning: [$tool] no $dot (or .kilocode for kilocode) in probe output - skipped" >&2
        printf "%s\t0\t0\t0\n" "$tool"
        return
    fi
    
    # Get lists of files
    local source_files
    local target_files
    source_files=$(get_relative_files "$source_dir")
    target_files=$(get_relative_files "$target_dir")
    
    # Calculate added/removed/updated
    local added=0 updated=0 removed=0
    
    # Create temp files for comparison
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local src_list="$tmp_dir/src.txt"
    local tgt_list="$tmp_dir/tgt.txt"
    
    echo "$source_files" > "$src_list"
    echo "$target_files" > "$tgt_list"
    
    # Added files (in source but not target)
    added=$(comm -13 "$tgt_list" "$src_list" | wc -l | tr -d ' ')
    
    # Removed files (in target but not source)
    removed=$(comm -23 "$tgt_list" "$src_list" | wc -l | tr -d ' ')
    
    # Common files - need to check for updates
    local common_files
    common_files=$(comm -12 "$tgt_list" "$src_list")
    
    while IFS= read -r rel; do
        local src_file="$source_dir/$rel"
        local tgt_file="$target_dir/$rel"
        
        if [[ ! -f "$tgt_file" ]] || ! cmp -s "$src_file" "$tgt_file"; then
            ((updated++))
        fi
    done <<< "$common_files"
    
    # Cleanup
    rm -rf "$tmp_dir"
    
    # Actually sync if not dry run
    if [[ "$dry_run" != "true" ]]; then
        rm -rf "$target_dir"
        mkdir -p "$(dirname "$target_dir")"
        cp -r "$source_dir" "$target_dir"
    fi
    
    printf "%s\t%s\t%s\t%s\n" "$tool" "$added" "$updated" "$removed"
}

parse_args "$@"

REPO=$(resolve_repo_root)
BUNDLE_ROOT="$REPO/content/openspec-bundle"

echo "Repo:    $REPO"
echo "Bundle:  $BUNDLE_ROOT"
echo "DryRun:  $DRY_RUN"

CLI_VERSION=$(test_openspec_available)
echo "OpenSpec CLI version: $CLI_VERSION"

# Create temporary directory
PROBE=$(mktemp -d "/tmp/opsx-refresh-XXXXXX")
echo ""
echo "Running openspec init in $PROBE ..."

INIT_OUTPUT=$(invoke_openspec_init "$PROBE")
if [[ "${DEBUG:-}" == "true" ]]; then
    echo "Debug: openspec init output:"
    echo "$INIT_OUTPUT"
fi

echo ""
echo "Per-tool diff:"

mkdir -p "$BUNDLE_ROOT"

# Process each tool
declare -a stats
for tool in "${TOOLS[@]}"; do
    stat_line=$(sync_tool_bundle "$tool" "$PROBE" "$BUNDLE_ROOT" "$DRY_RUN")
    stats+=("$stat_line")
done

# Print statistics
printf "  %-12s added=%-3s updated=%-3s removed=%-3s\n" "Tool" "+" "~" "-"
echo "  --------------------------------------"
for stat_line in "${stats[@]}"; do
    IFS=$'\t' read -r tool added updated removed <<< "$stat_line"
    printf "  %-12s added=%-3s updated=%-3s removed=%-3s\n" \
           "$tool" "$added" "$updated" "$removed"
done

# Handle version.txt
VER_FILE="$BUNDLE_ROOT/version.txt"
EXISTING_VERSION=""
if [[ -f "$VER_FILE" ]]; then
    EXISTING_VERSION=$(cat "$VER_FILE" | sed 's/[[:space:]]*$//')
fi

echo ""
if [[ -z "$EXISTING_VERSION" ]]; then
    echo "version.txt: <new> -> $CLI_VERSION"
elif [[ "$EXISTING_VERSION" != "$CLI_VERSION" ]]; then
    echo "version.txt: $EXISTING_VERSION -> $CLI_VERSION"
else
    echo "version.txt: $CLI_VERSION (unchanged)"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    :
else
    echo -n "$CLI_VERSION" > "$VER_FILE"
fi

# Cleanup
rm -rf "$PROBE"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Dry run - no files modified. Re-run without --dry-run to apply."
else
    echo ""
    echo "Bundle refresh complete. Review \`git status\` and commit."
fi