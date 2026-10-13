#!/usr/bin/env python3
"""Convert a BFSOS CRUX ports tree to the scratchpkg `.spkgbuild` format.

The BFSOS ports tree is written for CRUX `pkgmk` plus BFSOS's pkgmk extension.
This tool rewrites every port for Venom Linux's `scratchpkg`, which differs in
five important ways:

  * the recipe file is `spkgbuild` (BFSOS names it `.spkgbuild` and points
    `pkgbuild` at that name through /etc/scratchpkg.conf),
  * variables are lowercase scalar shell variables, so `source=(a b)` becomes
    `source="a b"`,
  * `build()` is run from `$SRC` instead of from the extracted source
    directory,
  * there is no automatic patch application and no default build: the recipe
    must ask for both, which it does by sourcing
    /usr/libexec/bfs/spkgbuild-lib.sh, and
  * port names may not contain capital letters.

Conversions performed:

  # Description: / # URL: / # Maintainer: / # Depends on:
      -> # description : / # homepage : / # maintainer : / # depends :
  source=( ... )            -> source=" ... "
  renames=( ... SKIP ... )  -> <local-name>::<url> source entries (SKIP keeps
                               the URL basename); scratchpkg decides whether to
                               extract from the local name, which is what the
                               fork's "keep the archive opaque" renames (such
                               as .zipx, .xzblob, .noextract) relied on
  keep_libtool=1            -> options="libtool"
  an empty .nostrip marker  -> options="!strip"
  pkg_build()               -> build(), with pre_build/post_build called in the
                               order pkgmk's extension called them
  no build function         -> build() that enters the source directory,
                               applies the recipe's patches, and runs the
                               detected build system through the library
  bootstrap_build()         -> kept, plus a build() wrapper that stages into
                               $PKG when TOOLS is unset
  compat-32 ports           -> 32-bit compiler/pkg-config preamble
  a version containing "-"  -> a scratchpkg-valid version, with the upstream
                               string kept verbatim inside the source URLs
  libX11, SpiderMonkey, ... -> lowercased names, since pkgbuild rejects capital
                               letters in a port name (--lowercase-names pass)

Usage:

    scripts/bfs-ports-to-spkgbuild.py --write              # convert the tree
    scripts/bfs-ports-to-spkgbuild.py --lowercase-names     # fix capitalised names
    scripts/bfs-ports-to-spkgbuild.py --check               # validate a converted tree
    scripts/bfs-ports-to-spkgbuild.py                       # report only, no writes
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field

CONVERTER_TAG = "scripts/bfs-ports-to-spkgbuild.py"
LIBRARY_PATH = "/usr/libexec/bfs/spkgbuild-lib.sh"
LIBRARY_LINE = f". {LIBRARY_PATH}"
MISSING_DESCRIPTION = "(no description in the CRUX recipe)"

# `[^\S\n]` is horizontal whitespace only: plain `\s` would let these patterns
# run past the end of a header line and swallow the next one.
HEADER_KEYS = (
    ("description", r"^#[^\S\n]*Description[^\S\n]*:"),
    ("homepage", r"^#[^\S\n]*URL[^\S\n]*:"),
    ("maintainer", r"^#[^\S\n]*Maintainer[^\S\n]*:"),
    ("depends", r"^#[^\S\n]*Depends(?:[^\S\n]+on)?[^\S\n]*:"),
)

# CRUX writes header keys capitalised, converted recipes lowercase; match both
# when reading a recipe back for validation.
HEADER_RE = {key: re.compile(pattern, re.IGNORECASE) for key, pattern in HEADER_KEYS}

HANDLED_VARS = {"name", "version", "release", "source", "renames"}
KEEP_VARS = {"keep_static", "keep_doc", "keep_locale", "keep_libtool"}

FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=")


@dataclass
class Recipe:
    """A parsed port recipe."""

    path: str
    name: str = ""
    version: str = ""
    release: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    vars: list[tuple[str, str]] = field(default_factory=list)
    source: list[str] = field(default_factory=list)
    raw_source: str = ""
    renames: list[str] = field(default_factory=list)
    functions: dict[str, str] = field(default_factory=dict)
    function_order: list[str] = field(default_factory=list)

    @property
    def dirname(self) -> str:
        return os.path.basename(os.path.dirname(self.path))

    @property
    def keep_static(self) -> bool:
        return any(k == "keep_static" and v not in ("", "0") for k, v in self.vars)

    @property
    def keep_libtool(self) -> bool:
        return any(k == "keep_libtool" and v not in ("", "0") for k, v in self.vars)


# --------------------------------------------------------------------------
# Shell-aware tokenizer
# --------------------------------------------------------------------------


def _scan_line(
    line: str, quote: str | None, heredoc: str | None
) -> tuple[int, int, str | None, str | None]:
    """Scan one shell line.

    Returns (brace delta, paren delta, quote state, active here-document
    delimiter).  The scanner understands comments, both quote styles, backslash
    escapes, `${...}` expansions and here-documents, which is what makes it safe
    to find the end of a function (braces) or of a multi-line assignment
    (parens) whose text embeds shell, Python or config file content.
    """
    braces = 0
    parens = 0
    index = 0
    at_word_start = True
    while index < len(line):
        char = line[index]

        if quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == "\\":
                index += 1
            elif char == '"':
                quote = None
        elif char == "\\":
            index += 1
            at_word_start = False
        elif char == "#" and at_word_start:
            break
        elif char in "\"'":
            quote = char
            at_word_start = False
        elif char == "{":
            braces += 1
            at_word_start = False
        elif char == "}":
            braces -= 1
            at_word_start = False
        elif char == "(":
            parens += 1
            at_word_start = True
        elif char == ")":
            parens -= 1
            at_word_start = False
        elif line.startswith("<<<", index):
            index += 2
            at_word_start = False
        elif line.startswith("<<", index):
            index, heredoc = _read_heredoc_word(line, index + 2, heredoc)
            at_word_start = False
        else:
            at_word_start = char.isspace() or char in ";&|"
        index += 1
    return braces, parens, quote, heredoc


def _read_heredoc_word(line: str, index: int, heredoc: str | None) -> tuple[int, str | None]:
    if index < len(line) and line[index] == "-":
        index += 1
    while index < len(line) and line[index] in " \t":
        index += 1
    if index >= len(line):
        return index, heredoc
    if line[index] in "\"'":
        closer = line[index]
        end = line.find(closer, index + 1)
        if end == -1:
            return len(line), heredoc
        return end + 1, line[index + 1 : end]
    end = index
    while end < len(line) and not line[end].isspace() and line[end] not in ";|&<>()":
        end += 1
    word = line[index:end]
    return end, word or heredoc


def _heredoc_ends(line: str, delimiter: str) -> bool:
    return line.strip() == delimiter


def tokenize(text: str) -> list[tuple[str, str, str]]:
    """Split recipe text into ('comment'|'statement'|'function', name, text)."""
    lines = text.split("\n")
    tokens: list[tuple[str, str, str]] = []
    index = 0

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if not stripped:
            index += 1
            continue
        if stripped.startswith("#"):
            tokens.append(("comment", "", line))
            index += 1
            continue

        match = FUNC_RE.match(stripped)
        if match:
            name = match.group(1)
            depth = 0
            quote: str | None = None
            heredoc: str | None = None
            collected: list[str] = []
            while index < len(lines):
                current = lines[index]
                collected.append(current)
                if heredoc is not None:
                    if _heredoc_ends(current, heredoc):
                        heredoc = None
                    index += 1
                    continue
                braces, _parens, quote, heredoc = _scan_line(current, quote, heredoc)
                depth += braces
                index += 1
                if depth <= 0 and heredoc is None and quote is None:
                    break
            body = "\n".join(collected)
            # Drop the `name() {` header line and the closing brace line, so the
            # captured body is only the function's inner text.
            first_newline = body.find("\n")
            body = body[first_newline + 1 :] if first_newline != -1 else ""
            body_lines = body.split("\n")
            for position in range(len(body_lines) - 1, -1, -1):
                if not body_lines[position].strip():
                    continue
                if body_lines[position].strip() == "}":
                    del body_lines[position]
                break
            tokens.append(("function", name, "\n".join(body_lines)))
            continue

        # A top-level statement: keep consuming while it is obviously unfinished.
        collected = [line]
        quote = None
        heredoc = None
        braces = 0
        parens = 0
        while True:
            current = collected[-1]
            if heredoc is not None:
                if _heredoc_ends(current, heredoc):
                    heredoc = None
                    break
                if index + 1 >= len(lines):
                    break
                index += 1
                collected.append(lines[index])
                continue
            brace_delta, paren_delta, quote, heredoc = _scan_line(current, quote, heredoc)
            braces += brace_delta
            parens += paren_delta
            unresolved = (
                braces > 0
                or parens > 0
                or quote is not None
                or heredoc is not None
                or current.rstrip().endswith("\\")
            )
            if not unresolved:
                break
            if index + 1 >= len(lines):
                break
            index += 1
            collected.append(lines[index])
        tokens.append(("statement", "", "\n".join(collected)))
        index += 1

    return tokens


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------


def parse_recipe(path: str, converted: bool = False) -> Recipe:
    text = open(path, encoding="utf-8", errors="replace").read()
    recipe = Recipe(path=path)

    for kind, func_name, body in tokenize(text):
        if kind == "comment":
            _absorb_header(recipe, body.strip())
            continue

        if kind == "function":
            recipe.functions[func_name] = body
            recipe.function_order.append(func_name)
            continue

        stripped = body.strip()
        if not stripped:
            continue
        assign = ASSIGN_RE.match(stripped)
        if not assign:
            continue
        key = assign.group(1)
        value = stripped[len(key) + 1 :].strip()
        if key == "source":
            recipe.raw_source = value
            recipe.source = _split_array(value)
        elif key == "renames":
            recipe.renames = _split_array(value)
        elif key in ("name", "version", "release"):
            setattr(recipe, key, _unquote(value))
        else:
            recipe.vars.append((key, value))

    return recipe


def _absorb_header(recipe: Recipe, line: str) -> bool:
    for key, _pattern in HEADER_KEYS:
        regex = HEADER_RE[key]
        if regex.match(line):
            recipe.headers[key] = regex.sub("", line).strip()
            return True
    return False


def _split_array(value: str) -> list[str]:
    """Turn `( a b c )`, `" a b c "` or a quoted scalar into source entries."""
    value = value.strip()
    if value.startswith("("):
        value = value[1:]
        if value.endswith(")"):
            value = value[:-1]
    elif len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    entries: list[str] = []
    for raw_line in value.split("\n"):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        entries.extend(_unquote(entry) for entry in line.split())
    return [entry for entry in entries if entry]


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------


def clean_version(version: str) -> str:
    """scratchpkg forbids '-' in `version`."""
    return version.replace("-", ".", 1) if "-" in version else version


def split_version(version: str) -> tuple[str, str | None]:
    if "-" not in version:
        return version, None
    head, tail = version.split("-", 1)
    return head, tail


def _substitute_version(entries: list[str], raw_version: str) -> list[str]:
    """Rewrite `$version` in source URLs to the upstream (dashed) string."""
    out = []
    for entry in entries:
        if "$version" in entry or "${version}" in entry:
            entry = entry.replace("${version}", raw_version).replace("$version", raw_version)
        out.append(entry)
    return out


def source_block(recipe: Recipe) -> tuple[str, str | None]:
    """Build the source= line plus an optional rename warning.

    `renames` in this fork is a parallel array of local file names: SKIP keeps
    the URL basename, any other value is the name the file is stored under.
    scratchpkg spells that `<local-name>::<url>`.  The point of names such as
    `.zipx`, `.xzblob` and `.noextract` is that pkgmk (and now pkgbuild) only
    unpacks recognised archive extensions, so those files stay opaque until the
    recipe unpacks them itself.
    """
    raw_version = recipe.version
    clean = clean_version(raw_version)
    entries = (
        _substitute_version(list(recipe.source), raw_version)
        if clean != raw_version
        else list(recipe.source)
    )

    renamed_entries: list[str] = []
    warning = None

    for index, entry in enumerate(entries):
        rename = recipe.renames[index] if index < len(recipe.renames) else None
        basename = entry.rsplit("/", 1)[-1]
        if rename and rename != "SKIP" and rename != basename:
            if "://" in entry:
                renamed_entries.append(f"{rename}::{entry}")
                continue
            warning = f"local source {basename} is downloaded as {rename}; check the recipe"
        renamed_entries.append(entry)

    return f'source="{" ".join(renamed_entries)}"', warning


def body_needs_staging_exports(body: str) -> bool:
    return "$install_root" in body or "$INSTALL_ROOT" in body


def strip_bfs_helpers(body: str) -> tuple[str, int]:
    """Drop pkgmk-extension guard calls that have no scratchpkg meaning."""
    kept: list[str] = []
    removed = 0
    for line in body.split("\n"):
        if "_bfs_require_compat32_extension" in line:
            removed += 1
            continue
        kept.append(line)
    return "\n".join(kept), removed


LIFECYCLE_SOURCES = (("pre-install", "pre-install"), ("post-install", "post-install"))


def convert_lifecycle_scripts(port_dir: str, write: bool) -> bool:
    """Turn CRUX pre-install/post-install files into a scratchpkg `install` script.

    CRUX runs those files through pkgadd/pkginst; scratchpkg instead runs a
    single `install` script from the port directory with

        $1 = pre-install|post-install|pre-upgrade|post-upgrade|pre-remove|post-remove
        $2 = new version, $3 = old version (upgrade only)

    so the bodies are wrapped in the matching case arms.  The original CRUX
    files are left in place next to the generated script for reference.
    """
    arms: list[tuple[str, str]] = []
    for filename, action in LIFECYCLE_SOURCES:
        path = os.path.join(port_dir, filename)
        if not os.path.exists(path):
            continue
        body = open(path, encoding="utf-8", errors="replace").read()
        body_lines = [line for line in body.split("\n") if not line.startswith("#!")]
        while body_lines and not body_lines[0].strip():
            body_lines.pop(0)
        while body_lines and not body_lines[-1].strip():
            body_lines.pop()
        if not any(line.strip() for line in body_lines):
            continue
        arms.append((action, "\n".join(body_lines)))

    if not arms:
        return False

    out = [
        "#!/bin/sh",
        "#",
        f"# BFSOS scratchpkg install script, generated from the CRUX scripts by {CONVERTER_TAG}.",
        "# scratchpkg calls this with $1 = pre-install|post-install|pre-upgrade|",
        "# post-upgrade|pre-remove|post-remove, $2 = new version, $3 = old version.",
        "",
        "case $1 in",
    ]
    for action, body in arms:
        out.append(f"\t{action})")
        # Same re-indentation rules as build bodies: here-document contents and
        # multi-line quoted strings stay byte-exact.
        out.extend(render_body(body, prefix="\t\t"))
        out.append("\t\t;;")
    out += ["esac", ""]

    if write:
        with open(os.path.join(port_dir, "install"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(out))
    return True


def _strip_body_braces(body: str) -> str:
    """Return the inner text of a function body, with or without braces."""
    text = body.strip("\n")
    if text.lstrip().startswith("{"):
        text = text.lstrip()[1:]
    if text.rstrip().endswith("}"):
        text = text.rstrip()[:-1]
    return text.strip("\n")


def wrap_function(name: str, body: str) -> str:
    """Render `name() { ... }` from a body captured by the tokenizer."""
    inner = _strip_body_braces(body)
    if not inner.strip():
        return f"{name}() :"
    return f"{name}() {{\n{inner}\n}}"


def function_is_empty(body: str) -> bool:
    for line in body.split("\n"):
        line = line.strip()
        if line and not line.startswith("#") and line not in ("{", "}"):
            return False
    return True


def _scan_quotes(text: str, quote: str | None) -> str | None:
    """Quote state after consuming `text`, the way the shell reads it."""
    index = 0
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == "\\":
                index += 1
            elif char == '"':
                quote = None
        elif char == "\\":
            index += 1
        elif char in "\"'":
            quote = char
        index += 1
    return quote


def render_body(body: str, prefix: str = "\t") -> list[str]:
    """Re-indent a CRUX build body inside build().

    Two kinds of line are emitted byte-exact, because re-indenting them would
    change meaning: lines that start inside a quoted string (splitting a printf
    format across lines is legal shell) and lines inside a here-document, whose
    terminator often has to start in column 0.
    """
    lines = body.split("\n")
    states: list[tuple[str | None, str | None]] = []
    quote: str | None = None
    heredoc: str | None = None
    for line in lines:
        states.append((quote, heredoc))
        if heredoc is not None:
            if _heredoc_ends(line, heredoc):
                heredoc = None
            continue
        _braces, _parens, quote, declared = _scan_line(line, quote, None)
        if declared is not None:
            heredoc = declared

    outside = [
        line
        for line, (start_quote, start_heredoc) in zip(lines, states)
        if start_quote is None and start_heredoc is None and line.strip()
    ]
    common = min((len(line) - len(line.lstrip(" \t")) for line in outside), default=0)

    out: list[str] = []
    for line, (start_quote, start_heredoc) in zip(lines, states):
        if start_quote is not None or start_heredoc is not None:
            out.append(line)
        elif not line.strip():
            out.append("")
        else:
            out.append(prefix + line[common:])
    return out


def convert(recipe: Recipe, port_dir: str) -> str:
    """Return the .spkgbuild text for a parsed recipe."""
    notes: list[str] = []
    raw_version = recipe.version
    version, suffix = split_version(raw_version)
    if suffix is not None:
        notes.append(
            "scratchpkg rejects '-' in `version`; the upstream version "
            f"{raw_version} is kept verbatim in the source URLs below."
        )

    compat32 = os.path.exists(os.path.join(port_dir, ".32bit"))
    nostrip_marker = os.path.join(port_dir, ".nostrip")
    nostrip_empty = os.path.exists(nostrip_marker) and not open(
        nostrip_marker, encoding="utf-8", errors="replace"
    ).read().strip()

    source_text, rename_warning = source_block(recipe)
    if rename_warning:
        notes.append(rename_warning)
    if recipe.keep_static:
        notes.append("keep_static is implicit here: scratchpkg keeps *.a files.")
    if any(key in ("keep_doc", "keep_locale") for key, _ in recipe.vars):
        notes.append(
            "keep_doc/keep_locale have no per-port equivalent; scratchpkg's "
            "KEEP_DOC/KEEP_LOCALE in /etc/scratchpkg.conf decide globally."
        )

    # The port directory *is* the port name under scratchpkg (pkgbuild refuses
    # to build when the two differ), so that is authoritative.  A CRUX name=
    # that differs is recorded instead of being dropped.
    name = recipe.dirname.lower()
    if recipe.name and recipe.name != name:
        notes.append(f"the CRUX recipe called this package {recipe.name}")

    description = recipe.headers.get("description") or name
    out: list[str] = [
        f"# description : {description or MISSING_DESCRIPTION}",
        f"# homepage    : {recipe.headers.get('homepage', '')}",
        f"# maintainer  : {recipe.headers.get('maintainer', '')}",
        f"# depends     : {recipe.headers.get('depends', '')}",
        "#",
        f"# BFSOS scratchpkg recipe, converted from the CRUX Pkgfile by {CONVERTER_TAG}.",
        "# Build it with `pkgbuild` (or `scratch install <port>`) from this directory.",
    ]
    for note in notes:
        out.append(f"# {note}")
    out.append("")

    if compat32:
        out += [
            "# compat-32: build and stage 32-bit objects against /usr/lib32.",
            'export BFS_PKG_LIBDIR="/usr/lib32"',
            'export BFS_PKG_LIBDIR_NAME="lib32"',
            'export BFS_MULTILIB_HOST="${BFS_MULTILIB_HOST:-i686-pc-linux-gnu}"',
            'export PKG_CONFIG_LIBDIR="/usr/lib32/pkgconfig:/usr/share/pkgconfig"',
            'export CFLAGS="${CFLAGS:--O2 -march=x86-64 -pipe} -m32"',
            'export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"',
            'export CC="${CC:-gcc} -m32"',
            'export CXX="${CXX:-g++} -m32"',
            'export LDFLAGS="${LDFLAGS:-} -L/usr/lib32"',
            "",
        ]

    out += [LIBRARY_LINE, ""]

    out.append(f"name={name}")
    out.append(f"version={version}")
    out.append(f"release={recipe.release or '1'}")
    for key, value in recipe.vars:
        if key in KEEP_VARS:
            continue
        out.append(f"{key}={value}")

    options: list[str] = []
    if recipe.keep_libtool:
        options.append("libtool")
    if nostrip_empty:
        options.append("!strip")

    out.append(source_text)
    if options:
        out.append(f'options="{" ".join(options)}"')
    out.append("")

    body_source = recipe.functions.get("pkg_build") or recipe.functions.get("build")
    pre = recipe.functions.get("pre_build")
    post = recipe.functions.get("post_build")
    bootstrap = recipe.functions.get("bootstrap_build")
    pre_body, _removed = strip_bfs_helpers(pre) if pre else ("", 0)
    pre_usable = bool(pre) and not function_is_empty(pre_body)

    build_lines = [
        "build() {",
        "\t# scratchpkg calls build() from $SRC; enter the unpacked source tree.",
        "\tbfs_enter_srcdir || return 1",
    ]
    if recipe.source:
        build_lines.append("\tbfs_apply_patches || return 1")

    if body_source and body_source != bootstrap:
        if body_needs_staging_exports(body_source):
            build_lines.append('\texport install_root="$PKG"     # glibc-style staging')
            build_lines.append('\texport INSTALL_ROOT="$PKG"    # qt-style staging')
        if pre_usable:
            build_lines.append("\tpre_build || return 1")
        build_lines.extend(render_body(body_source))
        if post:
            build_lines.append("\tpost_build || return 1")
    elif bootstrap:
        build_lines += [
            "\t# bootstrap.sh calls bootstrap_build() with TOOLS pointing at the",
            "\t# toolchain root; a package build stages into $PKG instead.",
            '\tTOOLS="${TOOLS:-$PKG}"',
        ]
        if pre_usable:
            build_lines.append("\tpre_build || return 1")
        build_lines.append("\tbootstrap_build || return 1")
        if post:
            build_lines.append("\tpost_build || return 1")
    else:
        if pre_usable:
            build_lines.append("\tpre_build || return 1")
        build_lines += [
            "\t# No custom build steps in the CRUX recipe: run the build system",
            "\t# the pkgmk extension would have detected.",
            "\tbfs_standard_build",
        ]
        if post:
            build_lines.append("\tpost_build || return 1")
    build_lines.append("}")
    out.append("\n".join(build_lines))

    for extra in ("pre_build", "post_build", "bootstrap_build", "post_install"):
        if extra not in recipe.functions:
            continue
        if extra == "pre_build":
            if not pre_usable:
                continue
            out += ["", wrap_function("pre_build", pre_body)]
            continue
        out += ["", wrap_function(extra, recipe.functions[extra])]

    out.append("")
    return "\n".join(out)


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------


def validate(recipe: Recipe, port_dir: str, text: str) -> list[str]:
    """Structural checks on a converted recipe, mirroring pkgbuild's rules."""
    problems: list[str] = []
    name = os.path.basename(port_dir)
    if not recipe.name:
        problems.append("no name= variable")
    elif recipe.name != name:
        problems.append(f"name={recipe.name} does not match directory {name}")
    if any(char.isupper() for char in name):
        problems.append(f"port name {name} contains capital letters (rejected by pkgbuild)")
    if not recipe.headers.get("description"):
        problems.append("no '# description :' header (pkgbuild rejects an empty description)")
    if not recipe.version:
        problems.append("no version= variable")
    elif "-" in recipe.version:
        problems.append(f"version={recipe.version} contains '-' (rejected by pkgbuild)")
    if not recipe.release:
        problems.append("no release= variable")
    elif not recipe.release.isdigit() or not (1 <= int(recipe.release) <= 99):
        problems.append(f"release={recipe.release} is not a number between 1 and 99")
    if "build" not in recipe.functions:
        problems.append("no build() function")
    if "pkg_build" in recipe.functions:
        problems.append("pkg_build() still present")
    if recipe.raw_source.strip().startswith("("):
        problems.append("source is still a CRUX array")
    if "bfs_" in text and LIBRARY_LINE not in text:
        problems.append(f"calls library helpers but does not source {LIBRARY_PATH}")
    if (
        os.path.exists(os.path.join(port_dir, "post-install"))
        or os.path.exists(os.path.join(port_dir, "pre-install"))
    ) and not os.path.exists(os.path.join(port_dir, "install")):
        problems.append("CRUX pre/post-install scripts have no scratchpkg install script")
    return problems


# --------------------------------------------------------------------------
# Port-name lowercasing
# --------------------------------------------------------------------------


def fix_dependency_references(root: str, write: bool) -> int:
    """Make every `# depends :` entry name a port that exists in the tree.

    scratchpkg resolves ports by name, so a dependency spelled with upstream
    capitalisation (`libX11`) cannot be found once the port is `libx11`.  Any
    token that only differs from an existing port by case is lowercased; the
    rest are reported, because a few are pre-existing CRUX references to
    packages that are not ports at all.
    """
    ports: dict[str, str] = {}
    for port_dir in port_dirs(root):
        ports[os.path.basename(port_dir)] = port_dir

    depends_re = re.compile(
        r"^#[^\S\n]*depends[^\S\n]*:[^\S\n]*(.*)$", re.IGNORECASE | re.MULTILINE
    )
    fixed_recipes = 0
    unresolved: dict[str, list[str]] = {}

    for name, port_dir in sorted(ports.items()):
        recipe_path = os.path.join(port_dir, ".spkgbuild")
        if not os.path.exists(recipe_path):
            continue
        text = open(recipe_path, encoding="utf-8", errors="replace").read()
        match = depends_re.search(text)
        if not match:
            continue

        original = match.group(1).strip()
        tokens: list[str] = []
        stop = False
        for token in original.split():
            if token.startswith("#"):
                stop = True
                continue
            if stop:
                continue
            if token in ports:
                tokens.append(token)
            elif token.lower() in ports:
                tokens.append(token.lower())
            else:
                tokens.append(token)
                unresolved.setdefault(token, []).append(name)

        rebuilt = " ".join(tokens)
        if rebuilt != original:
            new_line = f"# depends     : {rebuilt}"
            new_text = depends_re.sub(new_line, text, count=1)
            fixed_recipes += 1
            if write:
                with open(recipe_path, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(new_text)

    print(f"recipes with rewritten dependency names: {fixed_recipes}")
    if unresolved:
        print(f"dependency names that are not ports in this tree ({len(unresolved)}):")
        for token, users in sorted(unresolved.items()):
            print(f"  {token}: referenced by {', '.join(sorted(users)[:3])}")
    return 0


def port_dirs(root: str) -> list[str]:
    found = []
    for dirpath, _dirs, files in os.walk(root):
        if "Pkgfile" in files or ".spkgbuild" in files:
            found.append(dirpath)
    return sorted(found)


def lowercase_names(root: str, write: bool) -> int:
    """Rename ports whose names contain capitals and fix their references.

    pkgbuild rejects capital letters in `name` and requires the port directory
    to match the name, so an upstream spelling such as `libX11` cannot be built
    as-is.  Renaming is safe as long as every recipe that depends on the port is
    updated in the same pass, which is what this does.
    """
    rename_map: dict[str, str] = {}
    for port_dir in port_dirs(root):
        name = os.path.basename(port_dir)
        if any(char.isupper() for char in name):
            rename_map[name] = name.lower()

    if not rename_map:
        print("no capitalised port names found")
        return 0

    parents: dict[str, str] = {}
    for port_dir in port_dirs(root):
        if os.path.basename(port_dir) in rename_map:
            parents[os.path.basename(port_dir)] = os.path.dirname(port_dir)

    collisions = {
        old: new
        for old, new in rename_map.items()
        if os.path.exists(os.path.join(parents.get(old, root), new))
    }

    print(f"ports to rename: {len(rename_map)}")

    # `libX11` must not eat the `libX11` inside `libX11-32-1.8.tar.xz`, and the
    # longer names must be tried first so `libX11-32` wins over `libX11`.
    alternatives = "|".join(sorted(map(re.escape, rename_map), key=len, reverse=True))
    reference_re = re.compile(r"(?<![A-Za-z0-9_+.-])(" + alternatives + r")(?![A-Za-z0-9_+.:/-])")

    touched: list[str] = []
    for port_dir in port_dirs(root):
        recipe_path = os.path.join(port_dir, ".spkgbuild")
        if not os.path.exists(recipe_path):
            continue
        text = open(recipe_path, encoding="utf-8", errors="replace").read()
        new_text = reference_re.sub(lambda m: rename_map[m.group(1)], text)
        if new_text != text:
            touched.append(recipe_path)
            if write:
                with open(recipe_path, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(new_text)

    print(f"recipes with updated references: {len(touched)}")

    for old, new in sorted(rename_map.items()):
        parent = parents.get(old)
        if write:
            if parent is None:
                print(f"  could not locate {old}", file=sys.stderr)
                continue
            os.rename(os.path.join(parent, old), os.path.join(parent, new))
            print(f"  {os.path.relpath(os.path.join(parent, new), os.getcwd())}")
        else:
            print(f"  would rename {old} -> {new}")

    if collisions:
        print(f"WARNING: {len(collisions)} rename target(s) already exist as other ports:")
        for old, new in sorted(collisions.items()):
            print(f"  {old} -> {new}")
        return 1
    return 0


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--root", default="ports", help="ports tree root (default: ports)")
    parser.add_argument("--write", action="store_true", help="write changes (default: report only)")
    parser.add_argument("--check", action="store_true", help="validate an already-converted tree")
    parser.add_argument(
        "--lowercase-names",
        action="store_true",
        help="rename ports with capital letters (pkgbuild rejects them) and fix references",
    )
    parser.add_argument(
        "--fix-deps",
        action="store_true",
        help="make '# depends :' entries resolve to ports that exist in the tree",
    )
    parser.add_argument("--quiet", action="store_true", help="only print problems and the summary")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"ports tree not found: {root}", file=sys.stderr)
        return 2

    if args.lowercase_names:
        return lowercase_names(root, args.write)

    if args.fix_deps:
        return fix_dependency_references(root, args.write)

    converted = 0
    skipped = 0
    problems: dict[str, list[str]] = {}
    renamed_sources = 0
    lifecycle = 0

    for port_dir in port_dirs(root):
        pkgfile = os.path.join(port_dir, "Pkgfile")
        spkgbuild = os.path.join(port_dir, ".spkgbuild")

        if args.check:
            if not os.path.exists(spkgbuild):
                problems[port_dir] = ["no .spkgbuild file"]
                continue
            text = open(spkgbuild, encoding="utf-8", errors="replace").read()
            found = validate(parse_recipe(spkgbuild), port_dir, text)
            if found:
                problems[port_dir] = found
            else:
                converted += 1
            continue

        if not os.path.exists(pkgfile):
            skipped += 1
            continue
        if port_dir == root:
            skipped += 1
            continue

        recipe = parse_recipe(pkgfile)
        broken = [
            name for name in recipe.function_order if not recipe.functions[name].strip()
        ]
        if broken:
            problems[port_dir] = [f"could not parse function(s): {', '.join(broken)}"]
            continue

        text = convert(recipe, port_dir)
        if recipe.renames and any(entry != "SKIP" for entry in recipe.renames):
            renamed_sources += 1

        if args.write:
            with open(spkgbuild, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            os.remove(pkgfile)
            if convert_lifecycle_scripts(port_dir, write=True):
                lifecycle += 1

        converted += 1
        if not args.quiet and converted % 200 == 0:
            print(f"  ... {converted} ports processed", file=sys.stderr)

    print(f"ports processed: {converted}")
    print(f"skipped (no Pkgfile): {skipped}")
    if renamed_sources:
        print(f"ports with translated renames= entries: {renamed_sources}")
    if lifecycle:
        print(f"ports with a generated install script: {lifecycle}")
    if problems:
        print(f"problems in {len(problems)} ports:")
        for path, found in sorted(problems.items()):
            print(f"  {os.path.relpath(path, os.getcwd())}: {'; '.join(found)}")
        return 1
    print("no problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
