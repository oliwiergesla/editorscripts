#!/bin/bash
#
# build.sh - EditorScripts Build Pipeline
#
# Bundles, minifies, and packages DaVinci Resolve Lua scripts for distribution.
# Auto-discovers scripts from src/scripts/ and an optional local personal/
# directory, extracting NAME and VERSION from the SCRIPT_INFO block at the
# top of each file.
#
# Usage:
#   ./build.sh                              Build all scripts + the suite installer
#   ./build.sh marker_sync                  Build a specific script (by source filename, no .lua)
#
# Pipeline per script:
#   1. luabundler  - Bundle ResolveKit + modules into single file
#   2. luasrcdiet  - Minify (strip whitespace, comments, rename locals)
#   3. Header      - Prepend copyright/license comment block
#   4. Installer   - Generate installer with embedded script content
#
# The utility tools in src/installer/tools/ are built once per run (minify +
# header, no bundling) and embedded into every installer; the installer puts
# them in EditorScripts/Tools/ when missing or older than the embedded version.
#
# A full run (no filter) also generates the suite installer: one installer
# embedding every production script from src/scripts/ with a per-script
# selection dialog and never-downgrade version checks. Filtered runs skip it
# (the suite needs all payloads freshly built); run ./build.sh to refresh it.
#
# Requirements:
#   - luabundler (npm): npm install -g luabundler
#   - luasrcdiet (luarocks): luarocks install luasrcdiet
#   - lua 5.4+

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"
LIB_DIR="$SRC_DIR/lib"
TEMPLATE="$SRC_DIR/installer/installer_template.lua"
EMBED_TOOL="$SCRIPT_DIR/tools/embed_content.lua"

# Copyright holder stamped into built file headers. If you fork this repo to
# build your own scripts, change this to your own name.
AUTHOR="Oliwier Gesla"
REPO_URL="https://github.com/oliwiergesla/editorscripts"

# Suite installer: one installer bundling every production script from
# src/scripts/. Bump SUITE_VERSION manually when publishing (repo convention).
SUITE_NAME="EditorScripts"
SUITE_VERSION="1.0.2"

# Source directories to scan for scripts (non-recursive; list subfolders explicitly)
SOURCE_DIRS=(
    "$SRC_DIR/scripts"
    "$SCRIPT_DIR/personal"
)

# Utility tools embedded into every installer (installed to EditorScripts/Tools/).
# The installer template has placeholders for exactly this many tools.
TOOL_SOURCES=(
    "$SRC_DIR/installer/tools/open_scripts_folder.lua"
    "$SRC_DIR/installer/tools/open_editorscripts_folder.lua"
)

# Temporary directory for intermediate build files
BUILD_TMP="$SCRIPT_DIR/.build_tmp"

# ============================================================================
# HELPERS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    if [ -d "$BUILD_TMP" ]; then
        rm -rf "$BUILD_TMP"
    fi
}

# Escape a string for use as a sed replacement with the | delimiter.
# Without this, '&' in a display name expands to the matched placeholder.
# Backslashes must be escaped first.
sed_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//|/\\|}
    s=${s//&/\\&}
    printf '%s' "$s"
}

# Escape a string for use inside a double-quoted Lua string literal in the
# generated SCRIPTS-table fragment. Backslashes must be escaped first.
lua_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

trap cleanup EXIT

# ============================================================================
# SCRIPT INFO EXTRACTION
# ============================================================================

# Extract NAME and VERSION from the SCRIPT_INFO block at the top of a Lua file.
# Sets EXTRACTED_NAME and EXTRACTED_VERSION variables.
extract_script_info() {
    local source_path="$1"

    # Read the first 10 lines (SCRIPT_INFO is always at the top)
    local head
    head=$(head -10 "$source_path")

    EXTRACTED_NAME=$(echo "$head" | grep 'NAME' | sed 's/.*NAME *= *"\(.*\)".*/\1/')
    EXTRACTED_VERSION=$(echo "$head" | grep 'VERSION' | sed 's/.*VERSION *= *"\(.*\)".*/\1/')

    if [ -z "$EXTRACTED_NAME" ] || [ -z "$EXTRACTED_VERSION" ]; then
        log_error "Could not extract SCRIPT_INFO from: $source_path"
        return 1
    fi
}

# ============================================================================
# DEPENDENCY CHECK
# ============================================================================

check_dependencies() {
    local missing=0

    if ! command -v luabundler &> /dev/null; then
        log_error "luabundler not found. Install with: npm install -g luabundler"
        missing=1
    fi

    if ! command -v luasrcdiet &> /dev/null; then
        log_error "luasrcdiet not found. Install with: luarocks install luasrcdiet"
        missing=1
    fi

    if ! command -v lua &> /dev/null; then
        log_error "lua not found. Install Lua 5.4+"
        missing=1
    fi

    if [ ! -f "$TEMPLATE" ]; then
        log_error "Installer template not found: $TEMPLATE"
        missing=1
    fi

    if [ ! -f "$EMBED_TOOL" ]; then
        log_error "Embed tool not found: $EMBED_TOOL"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# ============================================================================
# HEADER GENERATION
# ============================================================================

generate_header() {
    local display_name="$1"
    local version="$2"
    local year
    year=$(date +%Y)

    cat <<HEADER
--[[
================================================================================
${display_name} v${version}
Copyright (C) ${year} ${AUTHOR}
Website: editorscripts.com

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License v3.0 as published by the Free
Software Foundation. This program is distributed WITHOUT ANY WARRANTY; see
the license for details.

NOTE: This file is a minified build. The complete corresponding source code
      is available at: ${REPO_URL}
================================================================================
]]

HEADER
}

# ============================================================================
# DIST ARTIFACT NAMING
# ============================================================================

# Lowercase kebab-case for dist artifacts: "Markers to Stills" -> "markers-to-stills".
# Dots are dropped ("My.Script" -> "myscript") and "+" becomes "plus". Display
# names with spaces are only written at install time, where they read cleanly
# in the Workspace menu.
kebab_name() {
    printf '%s' "$1" \
        | sed -e 's/+/plus/g' -e 's/\.//g' \
        | tr '[:upper:]' '[:lower:]' \
        | tr ' ' '-'
}

# ============================================================================
# SCRIPTS-TABLE FRAGMENT GENERATION
# ============================================================================

# Writes the Lua SCRIPTS-table entries for the installer template's
# {{SCRIPTS_TABLE}} placeholder. Takes the output file followed by
# name/version/filename triplets; entry i gets a {{SCRIPTi_CONTENT}}
# placeholder that a later embed_content.lua pair fills with the payload.
generate_scripts_fragment() {
    local out_file="$1"
    shift
    : > "$out_file"

    local i=1
    while [ $# -gt 0 ]; do
        local name="$1"
        local version="$2"
        local filename="$3"
        shift 3

        cat >> "$out_file" <<FRAG
    {
        name = "$(lua_escape "$name")",
        version = "$(lua_escape "$version")",
        filename = "$(lua_escape "$filename")",
        content = [=====[
{{SCRIPT${i}_CONTENT}}
]=====],
    },
FRAG
        i=$((i + 1))
    done
}

# ============================================================================
# BUILD UTILITY TOOLS (embedded into every installer)
# ============================================================================

TOOL_NAMES=()
TOOL_VERSIONS=()
TOOL_FILES=()

# Production scripts collected during the build for the suite installer
SUITE_SCRIPT_NAMES=()
SUITE_SCRIPT_VERSIONS=()
SUITE_SCRIPT_FILES=()

build_tools() {
    log_info "Building utility tools..."
    mkdir -p "$BUILD_TMP/tools"

    local i=0
    for tool_source in "${TOOL_SOURCES[@]}"; do
        if [ ! -f "$tool_source" ]; then
            log_error "Tool source not found: $tool_source"
            exit 1
        fi
        if ! extract_script_info "$tool_source"; then
            exit 1
        fi

        # Tools are dependency-free (no require), so no bundling step
        local minified="$BUILD_TMP/tools/tool${i}_min.lua"
        local final="$BUILD_TMP/tools/tool${i}.lua"
        if ! luasrcdiet --basic --quiet "$tool_source" -o "$minified" 2>&1; then
            log_error "luasrcdiet failed for tool: $tool_source"
            exit 1
        fi
        generate_header "$EXTRACTED_NAME" "$EXTRACTED_VERSION" > "$final"
        cat "$minified" >> "$final"

        TOOL_NAMES+=("$EXTRACTED_NAME")
        TOOL_VERSIONS+=("$EXTRACTED_VERSION")
        TOOL_FILES+=("$final")
        log_success "  Tool: $EXTRACTED_NAME v$EXTRACTED_VERSION"
        i=$((i + 1))
    done
}

# ============================================================================
# BUILD A SINGLE SCRIPT
# ============================================================================

build_script() {
    local source_path="$1"

    # Extract metadata from source file
    if ! extract_script_info "$source_path"; then
        return 1
    fi

    local display_name="$EXTRACTED_NAME"
    local version="$EXTRACTED_VERSION"
    local kebab
    kebab=$(kebab_name "$display_name")
    local dist_dirname="$kebab"
    local dist_path="$DIST_DIR/$dist_dirname"
    local script_filename="${kebab}-v${version}.lua"
    local install_filename="${display_name}.lua"
    local installer_filename="${kebab}-v${version}-installer.lua"

    echo ""
    log_info "Building: $display_name v$version"
    echo "  Source: $source_path"

    # Create temp and dist directories
    mkdir -p "$BUILD_TMP"
    mkdir -p "$dist_path"

    local bundled="$BUILD_TMP/bundled.lua"
    local minified="$BUILD_TMP/minified.lua"
    local with_header="$BUILD_TMP/with_header.lua"
    local installer_temp="$BUILD_TMP/installer_temp.lua"

    # Step 1: Bundle dependencies
    log_info "  Bundling dependencies..."
    if ! luabundler bundle "$source_path" \
        -p "$LIB_DIR/?.lua" \
        -p "$LIB_DIR/modules/?.lua" \
        -o "$bundled" 2>&1; then
        log_error "  luabundler failed"
        return 1
    fi
    local bundled_size
    bundled_size=$(wc -c < "$bundled" | tr -d ' ')
    log_success "  Bundled: ${bundled_size} bytes"

    # Break luabundler's entry tail call. LuaJIT tail calls replace the
    # caller's stack frame, so `return __bundle_require("__root")` erases the
    # main chunk from the call stack and ResolveKit's getScriptPath() (a
    # stack walk for the main chunk) fails in every bundled build while dev
    # copies work. Keep the entry invocation non-tail.
    if [ "$(tail -n 1 "$bundled")" != 'return __bundle_require("__root")' ]; then
        log_error "  Unexpected luabundler footer; update the entry tail-call fix"
        return 1
    fi
    { sed '$d' "$bundled"; printf 'local __bundle_main = __bundle_require("__root")\nreturn __bundle_main\n'; } > "$bundled.notail"
    mv "$bundled.notail" "$bundled"

    # Step 2: Minify
    log_info "  Minifying..."
    if ! luasrcdiet --basic --quiet "$bundled" -o "$minified" 2>&1; then
        log_error "  luasrcdiet failed"
        return 1
    fi
    local minified_size
    minified_size=$(wc -c < "$minified" | tr -d ' ')
    local reduction
    reduction=$(( (bundled_size - minified_size) * 100 / bundled_size ))
    log_success "  Minified: ${minified_size} bytes (${reduction}% reduction)"

    # Step 3: Add header
    log_info "  Adding header..."
    generate_header "$display_name" "$version" > "$with_header"
    cat "$minified" >> "$with_header"

    # Step 4: Copy to dist
    local dist_script="$dist_path/$script_filename"
    cp "$with_header" "$dist_script"
    local final_size
    final_size=$(wc -c < "$dist_script" | tr -d ' ')
    log_success "  Script: $dist_script ($final_size bytes)"

    # Step 5: Generate installer
    log_info "  Generating installer..."

    # Start with the template and replace metadata placeholders using sed
    sed \
        -e "s|{{INSTALLER_TITLE}}|$(sed_escape "${display_name}")|g" \
        -e "s|{{INSTALLER_VERSION}}|$(sed_escape "${version}")|g" \
        -e "s|{{TOOL1_NAME}}|$(sed_escape "${TOOL_NAMES[0]}")|g" \
        -e "s|{{TOOL1_VERSION}}|$(sed_escape "${TOOL_VERSIONS[0]}")|g" \
        -e "s|{{TOOL1_FILENAME}}|$(sed_escape "${TOOL_NAMES[0]}.lua")|g" \
        -e "s|{{TOOL2_NAME}}|$(sed_escape "${TOOL_NAMES[1]}")|g" \
        -e "s|{{TOOL2_VERSION}}|$(sed_escape "${TOOL_VERSIONS[1]}")|g" \
        -e "s|{{TOOL2_FILENAME}}|$(sed_escape "${TOOL_NAMES[1]}.lua")|g" \
        "$TEMPLATE" > "$installer_temp"

    # Generate the 1-entry SCRIPTS-table fragment, then embed it and the
    # payloads (the fragment pair must come first: it introduces the
    # {{SCRIPT1_CONTENT}} placeholder the next pair fills)
    local fragment="$BUILD_TMP/scripts_fragment.lua"
    generate_scripts_fragment "$fragment" "$display_name" "$version" "$install_filename"

    local dist_installer="$dist_path/$installer_filename"
    lua "$EMBED_TOOL" "$installer_temp" "$dist_installer" \
        "raw:{{SCRIPTS_TABLE}}" "$fragment" \
        "{{SCRIPT1_CONTENT}}" "$dist_script" \
        "{{TOOL1_CONTENT}}" "${TOOL_FILES[0]}" \
        "{{TOOL2_CONTENT}}" "${TOOL_FILES[1]}"

    local installer_size
    installer_size=$(wc -c < "$dist_installer" | tr -d ' ')
    log_success "  Installer: $dist_installer ($installer_size bytes)"

    # Clean up temp files for this script
    rm -f "$bundled" "$minified" "$with_header" "$installer_temp" "$fragment"

    # Collect production scripts for the suite installer
    case "$source_path" in
        "$SRC_DIR/scripts/"*)
            SUITE_SCRIPT_NAMES+=("$display_name")
            SUITE_SCRIPT_VERSIONS+=("$version")
            SUITE_SCRIPT_FILES+=("$dist_script")
            ;;
    esac

    log_success "  Done: $display_name v$version"
    echo "  Output: $dist_path/"
}

# ============================================================================
# BUILD THE SUITE INSTALLER (all production scripts in one installer)
# ============================================================================

build_suite() {
    local suite_kebab
    suite_kebab=$(kebab_name "$SUITE_NAME")
    local suite_dist="$DIST_DIR/$suite_kebab"
    local installer_filename="${suite_kebab}-v${SUITE_VERSION}-installer.lua"

    echo ""
    log_info "Building: $SUITE_NAME v$SUITE_VERSION (${#SUITE_SCRIPT_NAMES[@]} scripts)"

    # Sort the collected scripts alphabetically by display name for a stable
    # dialog order (tab-delimited; display names never contain tabs)
    local sorted_names=()
    local sorted_versions=()
    local sorted_files=()
    local i name version file
    while IFS=$'\t' read -r name version file; do
        sorted_names+=("$name")
        sorted_versions+=("$version")
        sorted_files+=("$file")
    done < <(
        for i in "${!SUITE_SCRIPT_NAMES[@]}"; do
            printf '%s\t%s\t%s\n' "${SUITE_SCRIPT_NAMES[$i]}" "${SUITE_SCRIPT_VERSIONS[$i]}" "${SUITE_SCRIPT_FILES[$i]}"
        done | sort
    )

    # Guard: duplicate display names would collide on disk at install time
    local prev_name=""
    for i in "${!sorted_names[@]}"; do
        if [ "${sorted_names[$i]}" = "$prev_name" ]; then
            log_error "Duplicate script display name: ${sorted_names[$i]} - suite installer not built"
            return 1
        fi
        prev_name="${sorted_names[$i]}"
    done

    # Sanity check: the first VERSION literal in each payload must match the
    # collected version (the installer's installed-version detection reads it)
    for i in "${!sorted_files[@]}"; do
        local payload_version
        payload_version=$(grep -oE 'VERSION *= *"[^"]*"' "${sorted_files[$i]}" | head -1 | sed 's/.*"\(.*\)"/\1/')
        if [ "$payload_version" != "${sorted_versions[$i]}" ]; then
            log_error "Version mismatch in ${sorted_files[$i]}: payload has '$payload_version', expected '${sorted_versions[$i]}'"
            return 1
        fi
    done

    mkdir -p "$BUILD_TMP"
    mkdir -p "$suite_dist"

    # Generate the N-entry SCRIPTS-table fragment
    local fragment="$BUILD_TMP/suite_fragment.lua"
    local triplets=()
    for i in "${!sorted_names[@]}"; do
        triplets+=("${sorted_names[$i]}" "${sorted_versions[$i]}" "${sorted_names[$i]}.lua")
    done
    generate_scripts_fragment "$fragment" "${triplets[@]}"

    # Replace metadata placeholders
    local installer_temp="$BUILD_TMP/suite_installer_temp.lua"
    sed \
        -e "s|{{INSTALLER_TITLE}}|$(sed_escape "$SUITE_NAME")|g" \
        -e "s|{{INSTALLER_VERSION}}|$(sed_escape "$SUITE_VERSION")|g" \
        -e "s|{{TOOL1_NAME}}|$(sed_escape "${TOOL_NAMES[0]}")|g" \
        -e "s|{{TOOL1_VERSION}}|$(sed_escape "${TOOL_VERSIONS[0]}")|g" \
        -e "s|{{TOOL1_FILENAME}}|$(sed_escape "${TOOL_NAMES[0]}.lua")|g" \
        -e "s|{{TOOL2_NAME}}|$(sed_escape "${TOOL_NAMES[1]}")|g" \
        -e "s|{{TOOL2_VERSION}}|$(sed_escape "${TOOL_VERSIONS[1]}")|g" \
        -e "s|{{TOOL2_FILENAME}}|$(sed_escape "${TOOL_NAMES[1]}.lua")|g" \
        "$TEMPLATE" > "$installer_temp"

    # Embed the fragment first, then every payload it references
    local embed_args=("raw:{{SCRIPTS_TABLE}}" "$fragment")
    for i in "${!sorted_files[@]}"; do
        embed_args+=("{{SCRIPT$((i + 1))_CONTENT}}" "${sorted_files[$i]}")
    done
    embed_args+=("{{TOOL1_CONTENT}}" "${TOOL_FILES[0]}")
    embed_args+=("{{TOOL2_CONTENT}}" "${TOOL_FILES[1]}")

    local dist_installer="$suite_dist/$installer_filename"
    if ! lua "$EMBED_TOOL" "$installer_temp" "$dist_installer" "${embed_args[@]}"; then
        log_error "Suite installer embed failed"
        return 1
    fi

    rm -f "$fragment" "$installer_temp"

    local installer_size
    installer_size=$(wc -c < "$dist_installer" | tr -d ' ')
    log_success "  Installer: $dist_installer ($installer_size bytes)"
    log_success "  Done: $SUITE_NAME v$SUITE_VERSION"
    echo "  Output: $suite_dist/"
}

# ============================================================================
# MAIN
# ============================================================================

echo ""
echo "============================================================"
echo "  EditorScripts Build Pipeline"
echo "============================================================"

check_dependencies

# Build the utility tools once; every installer embeds them
build_tools

# Determine which scripts to build
FILTER="${1:-}"
BUILT=0
FAILED=0
TOTAL=0
SUITE_FAILED=0

# Collect all source files from configured directories
ALL_SOURCES=()
for dir in "${SOURCE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        for f in "$dir"/*.lua; do
            [ -f "$f" ] && ALL_SOURCES+=("$f")
        done
    fi
done

for source_path in "${ALL_SOURCES[@]}"; do
    source_base="$(basename "$source_path" .lua)"

    # If a filter is specified, match against source filename (without .lua)
    if [ -n "$FILTER" ]; then
        if [ "$source_base" != "$FILTER" ]; then
            continue
        fi
    fi

    TOTAL=$((TOTAL + 1))

    if build_script "$source_path"; then
        BUILT=$((BUILT + 1))
    else
        FAILED=$((FAILED + 1))
        # A failed production script must block the suite (a personal/ failure must not)
        case "$source_path" in
            "$SRC_DIR/scripts/"*) SUITE_FAILED=$((SUITE_FAILED + 1)) ;;
        esac
    fi
done

# Generate the suite installer only on a clean full build: a filtered run has
# just one fresh payload, and scavenging stale dist folders is fragile
if [ -z "$FILTER" ] && [ "$SUITE_FAILED" -eq 0 ] && [ "${#SUITE_SCRIPT_NAMES[@]}" -gt 0 ]; then
    build_suite || log_error "Suite installer build failed"
elif [ -n "$FILTER" ] && [ "$TOTAL" -gt 0 ]; then
    log_info "Suite installer not regenerated (single-script build); run ./build.sh to refresh"
elif [ "$SUITE_FAILED" -gt 0 ]; then
    log_warn "Suite installer skipped: $SUITE_FAILED production script(s) failed to build"
fi

# Summary
echo ""
echo "============================================================"
if [ "$TOTAL" -eq 0 ]; then
    if [ -n "$FILTER" ]; then
        log_warn "No script found matching: $FILTER"
        echo ""
        echo "Available scripts:"
        for source_path in "${ALL_SOURCES[@]}"; do
            source_base="$(basename "$source_path" .lua)"
            echo "  $source_base"
        done
    else
        log_warn "No scripts found in source directories"
    fi
elif [ "$FAILED" -eq 0 ]; then
    log_success "Build complete: $BUILT/$TOTAL scripts built successfully"
else
    log_warn "Build complete: $BUILT/$TOTAL succeeded, $FAILED failed"
fi
echo "============================================================"
echo ""
