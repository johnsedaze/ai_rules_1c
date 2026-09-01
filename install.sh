#!/usr/bin/env bash
# 1c-rules installer (bash channel)
#
# SYNOPSIS
#   1c-rules installer (bash/macOS channel)
#
# DESCRIPTION
#   Implements the same installation protocol as AGENT-INSTALL.md but
#   deterministically through a CLI. Reads content/ and adapters/*.yaml,
#   writes per-tool files and a shared .ai-rules.json manifest.
#
#   Commands:
#     init     First install (no manifest yet, or force re-init).
#     update   Update installed rules to the current repo version.
#     add      Add rules for an additional tool.
#     remove   Remove rules (optionally only for one tool).
#     doctor   Read-only diagnostic.
#     eject    Delete manifest; leave files in place.
#
# USAGE
#   ./install.sh [command] [options]
#
#   Options:
#     --tool TOOL          For add/remove: the tool id to operate on.
#     --tools TOOL1,TOOL2  For init/update: explicit list of tool ids.
#     --source PATH|URL    Source repository URL or local path.
#     --project-root PATH  Project root directory. Default: current directory.
#     --non-interactive    Do not prompt.
#     --assume-yes         Answer yes to confirmation prompts.
#
# EXAMPLES
#   ./install.sh init --tools cursor,claude-code --non-interactive
#   ./install.sh update --assume-yes
#   ./install.sh init --source https://github.com/comol/ai_rules_1c --assume-yes
#
# REQUIREMENTS
#   bash 3.2+, python3, git, shasum (macOS) or sha256sum (Linux)
#
# NOTES
#   Protocol version: 1.0. See AGENT-INSTALL.md for the specification.

set -euo pipefail

# ============================================================================
# SECTION 1: CONSTANTS
# ============================================================================

PROTOCOL_VERSION='1.0'
MANIFEST_FILE_NAME='.ai-rules.json'
AGENTS_MD_FILE_NAME='AGENTS.md'
USER_RULES_FILE_NAME='USER-RULES.md'
MEMORY_FILE_NAME='memory.md'
LLM_RULES_FILE_NAME='LLM-RULES.md'
SUPPORTED_TOOLS='cursor claude-code codex opencode kilocode kimi qwen command-code cline pi other'
LAST_CHANNEL='bash'

# ============================================================================
# SECTION 2: ARGUMENT PARSING
# ============================================================================

COMMAND='init'
ARG_TOOL=''
ARG_TOOLS=''
ARG_SOURCE=''
ARG_PROJECT_ROOT=''
NON_INTERACTIVE=0
ASSUME_YES=0

usage() {
    # Extract USAGE section from script comments
    # macOS sed workaround
    local start_line=$(grep -n '^# USAGE' "$0" | cut -d: -f1)
    local end_line=$(grep -n '^# [A-Z]' "$0" | grep -A1 "^$start_line:" | tail -1 | cut -d: -f1)
    if [[ -n "$start_line" && -n "$end_line" && "$start_line" -lt "$end_line" ]]; then
        sed -n "$((start_line+1)),$((end_line-1))p" "$0" | sed 's/^# \?//'
    else
        # Fallback simple usage
        echo "Usage: $0 [command] [options]"
        echo "Commands: init, update, add, remove, doctor, eject"
        echo "Options: --tool TOOL --tools TOOL1,TOOL2 --source PATH|URL --project-root PATH --non-interactive --assume-yes"
    fi
    exit 0
}

# First positional arg is command
if [[ $# -gt 0 && "$1" != --* ]]; then
    COMMAND="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tool)          ARG_TOOL="$2";         shift 2 ;;
        --tools)         ARG_TOOLS="$2";        shift 2 ;;
        --source)        ARG_SOURCE="$2";       shift 2 ;;
        --project-root)  ARG_PROJECT_ROOT="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=1;   shift ;;
        --assume-yes)    ASSUME_YES=1;          shift ;;
        --help|-h)       usage ;;
        *)  write_err "Unknown argument: $1"; exit 1 ;;
    esac
done

# Validate command
case "$COMMAND" in
    init|update|add|remove|doctor|eject) ;;
    *) echo "ERROR: Unknown command: $COMMAND. Use: init, update, add, remove, doctor, eject" >&2; exit 1 ;;
esac

# ============================================================================
# SECTION 3: LOGGING AND USER INPUT
# ============================================================================

# ANSI colors (disabled when not a tty)
if [[ -t 1 ]]; then
    CLR_RESET='\033[0m'
    CLR_YELLOW='\033[33m'
    CLR_RED='\033[31m'
    CLR_CYAN='\033[36m'
else
    CLR_RESET=''
    CLR_YELLOW=''
    CLR_RED=''
    CLR_CYAN=''
fi

write_info() { echo "$1"; }
write_warn() { echo -e "${CLR_YELLOW}WARN: $1${CLR_RESET}"; }
write_err()  { echo -e "${CLR_RED}ERROR: $1${CLR_RESET}" >&2; }
write_section() { echo -e "\n${CLR_CYAN}== $1 ==${CLR_RESET}"; }

# read_yesno "prompt" default(0=no,1=yes)  -> returns 0(yes) or 1(no)
read_yesno() {
    local prompt="$1"
    local default="${2:-1}"
    if [[ "$NON_INTERACTIVE" -eq 1 || "$ASSUME_YES" -eq 1 ]]; then return 0; fi
    local suffix='[Y/n]'
    [[ "$default" -eq 0 ]] && suffix='[y/N]'
    local ans
    read -r -p "$prompt $suffix " ans
    [[ -z "$ans" ]] && return $((1 - default))
    [[ "$ans" =~ ^[Yy] ]] && return 0 || return 1
}

# read_choice "prompt" "opt1 opt2 opt3" "default" -> echoes chosen option
read_choice() {
    local prompt="$1"
    local opts="$2"
    local default="$3"
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then echo "$default"; return; fi
    local opts_display=''
    for o in $opts; do
        [[ "$o" == "$default" ]] && opts_display+="[$o]/" || opts_display+="$o/"
    done
    opts_display="${opts_display%/}"
    local ans
    read -r -p "$prompt ($opts_display) " ans
    [[ -z "$ans" ]] && echo "$default" && return
    for o in $opts; do
        [[ "$o" == "$ans"* ]] && echo "$o" && return
    done
    echo "$default"
}

# ============================================================================
# SECTION 4: FILE IO AND HASHING
# ============================================================================

# SHA256 of a file
file_sha256() {
    local path="$1"
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        sha256sum "$path" | awk '{print $1}'
    fi
}

# SHA256 of a string
string_sha256() {
    local s="$1"
    if command -v shasum &>/dev/null; then
        printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
    else
        printf '%s' "$s" | sha256sum | awk '{print $1}'
    fi
}

# Write a file ensuring the parent directory exists (UTF-8 no BOM)
write_text_file() {
    local path="$1"
    local content="$2"
    local dir
    dir="$(dirname "$path")"
    [[ -n "$dir" && ! -d "$dir" ]] && mkdir -p "$dir"
    printf '%s' "$content" > "$path"
}

# Read an entire file
read_text_file() {
    cat "$1"
}

# ============================================================================
# SECTION 5: PYTHON3 YAML/JSON ENGINE
# ============================================================================
# All complex parsing (YAML, frontmatter, JSON manifest, template rendering)
# is delegated to Python3, which is standard on macOS (Xcode CLT / Homebrew).

_py3_engine_file="${TMPDIR:-/tmp}/1c-rules-py-engine-$$.py"
cat >"$_py3_engine_file" <<'PYEOF'
import sys, json, os, re, hashlib, datetime
from collections import OrderedDict

# ---- YAML helpers -----------------------------------------------------------

def yaml_scalar(raw):
    raw = raw.strip()
    if raw in ('true',): return True
    if raw in ('false',): return False
    if raw in ('null', '~', ''): return None
    try: return int(raw)
    except ValueError: pass
    if (raw.startswith('"') and raw.endswith('"')):
        return raw[1:-1].replace('\\"', '"')
    if (raw.startswith("'") and raw.endswith("'")):
        return raw[1:-1]
    return raw

def yaml_flow_split(raw):
    """Split a flow-style comma-separated string honouring brackets/quotes."""
    parts, buf, d_br, d_brace, in_s, in_d = [], '', 0, 0, False, False
    for ch in raw:
        if not in_d and ch == "'": in_s = not in_s; buf += ch; continue
        if not in_s and ch == '"': in_d = not in_d; buf += ch; continue
        if in_s or in_d: buf += ch; continue
        if ch == '[': d_br += 1; buf += ch
        elif ch == ']': d_br -= 1; buf += ch
        elif ch == '{': d_brace += 1; buf += ch
        elif ch == '}': d_brace -= 1; buf += ch
        elif ch == ',' and d_br == 0 and d_brace == 0:
            if buf.strip(): parts.append(buf.strip())
            buf = ''
        else: buf += ch
    if buf.strip(): parts.append(buf.strip())
    return parts

def yaml_inline_value(raw):
    raw = raw.strip()
    if raw.startswith('{') and raw.endswith('}'):
        inside = raw[1:-1].strip()
        if not inside: return OrderedDict()
        d = OrderedDict()
        for p in yaml_flow_split(inside):
            m = re.match(r'^("([^"]+)"|[\w!-][\w-]*)\s*:\s*(.*)$', p)
            if m:
                k = m.group(2) if m.group(2) else m.group(1)
                d[k] = yaml_inline_value(m.group(3))
        return d
    if raw.startswith('[') and raw.endswith(']'):
        inside = raw[1:-1].strip()
        if not inside: return []
        return [yaml_inline_value(p) for p in yaml_flow_split(inside)]
    return yaml_scalar(raw)

def strip_eol_comment(line):
    in_s, in_d, i = False, False, 0
    while i < len(line):
        ch = line[i]
        if not in_d and ch == "'": in_s = not in_s
        elif not in_s and ch == '"': in_d = not in_d
        elif not in_s and not in_d and ch == '#': return line[:i].rstrip()
        i += 1
    return line.rstrip()

class Parser:
    def __init__(self, lines): self.lines = lines; self.idx = 0

def yaml_parse_block(p, base_indent):
    result = OrderedDict()
    while p.idx < len(p.lines):
        line = p.lines[p.idx]
        if not line.strip(): p.idx += 1; continue
        indent = len(line) - len(line.lstrip())
        if indent < base_indent: break
        if indent > base_indent:
            raise ValueError(f"YAML parse error at line {p.idx+1}: unexpected indent")
        trim = line.strip()
        m = re.match(r'^("([^"]+)"|[\w!-][\w-]*)\s*:\s*(.*)$', trim)
        if not m: raise ValueError(f"YAML parse error at line {p.idx+1}: expected key-value, got '{trim}'")
        raw_key, quoted_key, raw_val = m.group(1), m.group(2), m.group(3)
        key = quoted_key if quoted_key else raw_key
        p.idx += 1
        if raw_val == '|':
            block_lines, block_indent = [], -1
            while p.idx < len(p.lines):
                l = p.lines[p.idx]
                if not l.strip(): block_lines.append(''); p.idx += 1; continue
                li = len(l) - len(l.lstrip())
                if li <= base_indent: break
                if block_indent < 0: block_indent = li
                if li < block_indent: break
                block_lines.append(l[block_indent:]); p.idx += 1
            while block_lines and block_lines[-1] == '': block_lines.pop()
            result[key] = '\n'.join(block_lines) + '\n'
        elif raw_val == '':
            # Nested block — could be dict or array. Skip blank lines first
            # (comment-only lines are blanked by the comment stripper above);
            # otherwise a comment between `key:` and its first child would be
            # mistaken for an empty value and break the nesting detection.
            while p.idx < len(p.lines) and not p.lines[p.idx].strip():
                p.idx += 1
            if p.idx < len(p.lines):
                nxt = p.lines[p.idx]
                ni = len(nxt) - len(nxt.lstrip())
                nt = nxt.strip()
                if nt.startswith('- ') or nt == '-':
                    result[key] = yaml_parse_block_array(p, ni)
                elif ni > base_indent:
                    result[key] = yaml_parse_block(p, ni)
                else:
                    result[key] = None
            else:
                result[key] = None
        else:
            result[key] = yaml_inline_value(raw_val)
    return result

def yaml_parse_block_array(p, base_indent):
    items = []
    while p.idx < len(p.lines):
        line = p.lines[p.idx]
        if not line.strip(): p.idx += 1; continue
        indent = len(line) - len(line.lstrip())
        if indent < base_indent: break
        if indent > base_indent: raise ValueError(f"Unexpected indent in array at line {p.idx+1}")
        trim = line.strip()
        if not trim.startswith('-'): break
        rest = trim[1:].lstrip()
        p.idx += 1
        if not rest:
            if p.idx < len(p.lines):
                ni = len(p.lines[p.idx]) - len(p.lines[p.idx].lstrip())
                items.append(yaml_parse_block(p, ni))
        else:
            m = re.match(r'^([\w-]+)\s*:\s*(.*)$', rest)
            if m:
                d = OrderedDict(); d[m.group(1)] = yaml_inline_value(m.group(2))
                items.append(d)
            else:
                items.append(yaml_inline_value(rest))
    return items

def parse_adapter_yaml(path):
    with open(path, 'r', encoding='utf-8') as f:
        raw_lines = f.read().splitlines()
    lines = [strip_eol_comment(l) for l in raw_lines]
    p = Parser(lines)
    return yaml_parse_block(p, 0)

def parse_frontmatter_yaml(text):
    result = OrderedDict()
    for line in text.splitlines():
        line = line.rstrip()
        if not line or line.startswith('#'): continue
        m = re.match(r'^([\w-]+)\s*:\s*(.*)$', line)
        if not m: continue
        k, v = m.group(1), m.group(2)
        result[k] = yaml_inline_value(v)
    return result

# ---- Frontmatter split ------------------------------------------------------

def split_frontmatter_body(text):
    lines = text.split('\n')
    if len(lines) < 2 or lines[0].rstrip() != '---':
        return None, text
    closer = -1
    for i in range(1, len(lines)):
        if lines[i].rstrip() == '---': closer = i; break
    if closer < 0: return None, text
    fm_text = '\n'.join(lines[1:closer])
    body = '\n'.join(lines[closer+1:])
    return parse_frontmatter_yaml(fm_text), body

def format_frontmatter_string_value(s):
    if re.match(r'^[\w./\-]+$', s) and s not in ('true','false','null','~'):
        return s
    return '"' + s.replace('"', '\\"') + '"'

def format_frontmatter_entry(k, v):
    if v is None: return f"{k}:"
    if isinstance(v, bool): return f"{k}: {'true' if v else 'false'}"
    if isinstance(v, int): return f"{k}: {v}"
    if isinstance(v, list):
        items = ['"' + str(x).replace('"', '\\"') + '"' for x in v]
        return f"{k}: [{', '.join(items)}]"
    if isinstance(v, str): return f"{k}: {format_frontmatter_string_value(v)}"
    return f"{k}: {v}"

def format_frontmatter(fm):
    if not fm: return ''
    lines = ['---']
    for k, v in fm.items():
        lines.append(format_frontmatter_entry(k, v))
    lines.append('---')
    return '\n'.join(lines)

# ---- Frontmatter operations -------------------------------------------------

def apply_frontmatter_ops(source, ops):
    src = OrderedDict(source) if source else OrderedDict()
    if not ops: return src
    keep = list(ops.get('keep') or [])
    drop = list(ops.get('drop') or [])
    rename = dict(ops.get('rename') or {})
    add_if = dict(ops.get('addIf') or {})
    if keep:
        src = OrderedDict((k, v) for k, v in src.items() if k in keep)
    elif drop:
        src = OrderedDict((k, v) for k, v in src.items() if k not in drop)
    if rename:
        src = OrderedDict((rename.get(k, k), v) for k, v in src.items())
    for cond, to_add in add_if.items():
        negated = cond.startswith('!')
        field = cond[1:] if negated else cond
        has_field = field in (source or {})
        truthy = has_field and bool((source or {}).get(field))
        should_add = (not truthy) if negated else truthy
        if should_add and isinstance(to_add, dict):
            src.update(to_add)
    return src

# ---- TOML helpers -----------------------------------------------------------

def format_toml_string(v): return '"' + v.replace('\\', '\\\\').replace('"', '\\"') + '"'
def format_toml_array(vals): return '[' + ', '.join(format_toml_string(x) for x in vals) + ']'

def codex_agent_template(template, fm, body):
    out_lines = []
    for line in template.split('\n'):
        placeholders = re.findall(r'\{([\w-]+)\}', line)
        has_missing = False
        for ph in placeholders:
            if ph == 'body': continue
            if not fm.get(ph): has_missing = True; break
        if has_missing: continue
        rendered = line
        for ph in placeholders:
            if ph == 'body': continue
            rendered = rendered.replace('{' + ph + '}', str(fm[ph]))
        rendered = rendered.replace('{body}', body)
        out_lines.append(rendered)
    return '\n'.join(out_lines)

# ---- MCP config renderers ---------------------------------------------------
# Mirrors the New-McpConfig-* family in install.ps1 — keep both in sync.

def servers_to_dict(servers):
    d = OrderedDict()
    for s in servers:
        entry = OrderedDict()
        if s.get('url'): entry['url'] = s['url']
        if s.get('connectionId'): entry['connection_id'] = s['connectionId']
        if s.get('description'): entry['description'] = s['description']
        if s.get('command'): entry['command'] = s['command']
        if s.get('args'): entry['args'] = s['args']
        if s.get('env'): entry['env'] = s['env']
        d[s['id']] = entry
    return d

def mcp_config_cursor(servers):
    return json.dumps(OrderedDict(mcpServers=servers_to_dict(servers)), indent=2, ensure_ascii=False)

def mcp_config_claude_code(servers):
    # Claude Code `.mcp.json` schema. Remote servers MUST carry an explicit
    # `"type": "http"` — without it Claude Code silently never loads the
    # server. Local entries use command/args/env only (no connection_id /
    # description — not part of the documented schema).
    d = OrderedDict()
    for s in servers:
        entry = OrderedDict()
        if s.get('url'):
            entry['type'] = 'http'
            entry['url'] = s['url']
            if s.get('headers'): entry['headers'] = s['headers']
        elif s.get('command'):
            entry['command'] = s['command']
            if s.get('args'): entry['args'] = s['args']
            if s.get('env'): entry['env'] = s['env']
        d[s['id']] = entry
    return json.dumps(OrderedDict(mcpServers=d), indent=2, ensure_ascii=False)

def mcp_config_kilocode(servers):
    # Current Kilo CLI / Kilo Code extension MCP schema (v7.x+, see
    # https://kilo.ai/docs/automate/mcp/using-in-cli): top-level `mcp` key
    # (not `mcpServers`), servers enabled by default.
    mcp = OrderedDict()
    for s in servers:
        entry = OrderedDict()
        if s.get('url'):
            entry['type'] = 'remote'
            entry['url'] = s['url']
        elif s.get('command'):
            entry['type'] = 'local'
            entry['command'] = [s['command']] + list(s.get('args') or [])
            if s.get('env'): entry['environment'] = s['env']
        entry['enabled'] = True
        mcp[s['id']] = entry
    return json.dumps(OrderedDict(mcp=mcp), indent=2, ensure_ascii=False)

def mcp_config_kimi(servers):
    # Kimi Code CLI reads the well-known `mcpServers` schema (adapters/kimi.yaml).
    return mcp_config_cursor(servers)

def mcp_config_other(servers):
    # Universal fallback adapter — same `mcpServers` schema as cursor.
    return mcp_config_cursor(servers)

def mcp_config_qwen(servers):
    # Qwen Code project MCP (`.qwen/settings.json` > mcpServers). HTTP
    # (streamable) servers MUST use `httpUrl`; `url` is SSE-only.
    d = OrderedDict()
    for s in servers:
        entry = OrderedDict()
        if s.get('url'):
            entry['httpUrl'] = s['url']
            if s.get('headers'): entry['headers'] = s['headers']
        elif s.get('command'):
            entry['command'] = s['command']
            if s.get('args'): entry['args'] = s['args']
            if s.get('env'): entry['env'] = s['env']
        d[s['id']] = entry
    return json.dumps(OrderedDict(mcpServers=d), indent=2, ensure_ascii=False)

def opencode_mcp_key(id_):
    # OpenCode exposes MCP tools as `<key>_<tool>`; some providers reject
    # function names not starting with a letter. Normalize `1c...` -> `onec...`
    # and guarantee any other non-letter-leading id gets an `mcp-` prefix.
    key = id_
    m = re.match(r'^1c(.*)$', key)
    if m:
        key = 'onec' + m.group(1)
    if not re.match(r'^[A-Za-z]', key):
        key = 'mcp-' + key
    return key

def mcp_config_opencode(servers):
    # OpenCode validates each entry with a strict schema: ONLY the
    # documented keys are allowed (type, url|command, enabled, environment).
    # An unknown key (e.g. description) makes OpenCode reject the whole
    # config, so servers silently never load.
    mcp = OrderedDict()
    for s in servers:
        entry = OrderedDict()
        if s.get('url'):
            entry['type'] = 'remote'
            entry['url'] = s['url']
        elif s.get('command'):
            entry['type'] = 'local'
            entry['command'] = [s['command']] + list(s.get('args') or [])
            if s.get('env'): entry['environment'] = s['env']
        entry['enabled'] = True
        mcp[opencode_mcp_key(s['id'])] = entry
    root = OrderedDict([('$schema', 'https://opencode.ai/config.json'), ('mcp', mcp)])
    return json.dumps(root, indent=2, ensure_ascii=False)

def mcp_config_codex(servers):
    lines = ['# MCP server configuration for Codex CLI', '# Generated by 1c-rules installer', '']
    for s in servers:
        lines.append(f'[mcp_servers."{s["id"]}"]')
        if s.get('url'): lines.append('url = ' + format_toml_string(s['url']))
        if s.get('connectionId'): lines.append('connection_id = ' + format_toml_string(s['connectionId']))
        if s.get('description'): lines.append('description = ' + format_toml_string(s['description']))
        if s.get('command'):
            lines.append('command = ' + format_toml_string(s['command']))
            if s.get('args'): lines.append('args = ' + format_toml_array(s['args']))
        lines.append('')
    return '\n'.join(lines)

def mcp_config(tool_id, servers):
    if tool_id == 'cursor': return mcp_config_cursor(servers)
    if tool_id in ('claude-code', 'command-code'): return mcp_config_claude_code(servers)
    if tool_id == 'codex': return mcp_config_codex(servers)
    if tool_id == 'opencode': return mcp_config_opencode(servers)
    if tool_id == 'kilocode': return mcp_config_kilocode(servers)
    if tool_id == 'kimi': return mcp_config_other(servers)
    if tool_id == 'qwen': return mcp_config_qwen(servers)
    if tool_id == 'other': return mcp_config_other(servers)
    raise ValueError(f"Unknown tool id: {tool_id}")

def merge_json_key(existing_path, rendered_json_str, merge_key):
    # Deep-merge helper for SHARED tool configs (`.kilo/kilo.json`,
    # `opencode.json`, `.qwen/settings.json`) that carry more than MCP
    # (instructions, permissions, model settings, …). Replaces only the
    # top-level `merge_key` with the freshly rendered value; every other
    # user key in the existing file is preserved as-is. Returns None when
    # the existing file cannot be parsed as JSON (caller falls back to
    # overwriting with the rendered content).
    try:
        with open(existing_path, 'r', encoding='utf-8') as f:
            existing = json.load(f, object_pairs_hook=OrderedDict)
    except Exception:
        return None
    rendered = json.loads(rendered_json_str, object_pairs_hook=OrderedDict)
    merged = OrderedDict()
    for k, v in existing.items():
        if k != merge_key:
            merged[k] = v
    if merge_key in rendered:
        merged[merge_key] = rendered[merge_key]
    for k, v in rendered.items():
        if k == merge_key: continue
        if k not in merged:
            merged[k] = v
    return json.dumps(merged, indent=2, ensure_ascii=False)

# ---- 1C project info --------------------------------------------------------

def detect_1c_project(root):
    cfg_xml = os.path.join(root, 'Configuration.xml')
    if not os.path.isfile(cfg_xml):
        return {'Detected': False}
    try:
        with open(cfg_xml, 'r', encoding='utf-8-sig') as f:
            text = f.read()
    except Exception:
        return {'Detected': False}
    info = {'Detected': True, 'Name': '', 'Synonym': '', 'Vendor': '', 'Version': '',
            'PlatformVersion': '', 'DefaultRunMode': '', 'FormMode': '', 'ScriptVariant': '',
            'Description': '', 'NamePrefix': '', 'IsExtension': False,
            'BspDetected': False, 'BspVersion': '', 'Subsystems': [], 'Counts': OrderedDict()}
    def tag_val(tag):
        m = re.search(rf'<{tag}[^>]*>(.*?)</{tag}>', text, re.S)
        return m.group(1).strip() if m else ''
    def lang_val(tag):
        m = re.search(rf'<{tag}[^>]*>.*?<ru>(.*?)</ru>', text, re.S)
        if m: return m.group(1).strip()
        m = re.search(rf'<{tag}[^>]*>(.*?)</{tag}>', text, re.S)
        return m.group(1).strip() if m else ''
    info['Name'] = tag_val('Name')
    info['Synonym'] = lang_val('Synonym')
    info['Vendor'] = tag_val('Vendor')
    info['Version'] = tag_val('Version')
    m = re.search(r'CompatibilityMode[^>]*>(.*?)<', text)
    if m: info['PlatformVersion'] = m.group(1).strip()
    m = re.search(r'DefaultRunMode[^>]*>(.*?)<', text)
    if m: info['DefaultRunMode'] = m.group(1).strip()
    m = re.search(r'UseManagedFormInOrdinaryApplication[^>]*>(.*?)<', text)
    use_mgd = m.group(1).strip().lower() == 'true' if m else False
    m = re.search(r'UseOrdinaryFormInManagedApplication[^>]*>(.*?)<', text)
    use_ord = m.group(1).strip().lower() == 'true' if m else False
    info['FormMode'] = 'mixed' if (use_mgd and use_ord) else ('ordinary' if use_ord else 'managed')
    m = re.search(r'ScriptVariant[^>]*>(.*?)<', text)
    if m: info['ScriptVariant'] = m.group(1).strip()
    info['Description'] = lang_val('Comment')
    m = re.search(r'NamePrefix[^>]*>(.*?)<', text)
    if m: info['NamePrefix'] = m.group(1).strip()
    info['IsExtension'] = bool(re.search(r'<ObjectPrefix>', text))
    # BSP detection
    bsp_module = os.path.join(root, 'CommonModules', 'StandardSubsystemsServer', 'Module.bsl')
    if not os.path.isfile(bsp_module):
        alt = [f for f in _walk_files(os.path.join(root, 'CommonModules'))
               if 'StandardSubsystemsServer' in f and f.endswith('.bsl')]
        info['BspDetected'] = bool(alt)
    else:
        info['BspDetected'] = True
    if info['BspDetected']:
        ver_file = os.path.join(root, 'CommonModules', 'StandardSubsystemsServer', 'Module.bsl')
        if os.path.isfile(ver_file):
            try:
                with open(ver_file, 'r', encoding='utf-8-sig') as f:
                    bsl = f.read(8192)
                m = re.search(r'LibraryVersion\s*=\s*"([\d.]+)"', bsl)
                if m: info['BspVersion'] = m.group(1)
            except: pass
    # Subsystems
    subs_dir = os.path.join(root, 'Subsystems')
    if os.path.isdir(subs_dir):
        info['Subsystems'] = sorted(
            d for d in os.listdir(subs_dir) if os.path.isdir(os.path.join(subs_dir, d)))
    # Metadata counts
    meta_dirs = ['Catalogs','Documents','DataProcessors','Reports','CommonModules',
                 'DocumentJournals','Enumerations','ChartsOfCharacteristicTypes',
                 'ChartsOfAccounts','ChartsOfCalculationTypes','BusinessProcesses',
                 'Tasks','ExchangePlans','Constants','Sequences','ScheduledJobs',
                 'FunctionalOptions','Roles','Subsystems','HTTPServices','WebServices']
    for md in meta_dirs:
        d = os.path.join(root, md)
        if os.path.isdir(d):
            n = sum(1 for x in os.scandir(d) if x.is_dir())
            if n: info['Counts'][md] = n
    return info

def _walk_files(base):
    result = []
    if not os.path.isdir(base): return result
    for root, dirs, files in os.walk(base):
        for f in files: result.append(os.path.join(root, f))
    return result

def format_1c_project_md(info):
    lines = []
    lines += ['# Проект 1С: Обзор', '',
              '> **Автоматически сгенерировано** установщиком `1c-rules` на основе `Configuration.xml`.',
              '> перезаписывать. Чтобы пересобрать с нуля, удалите файл и запустите `update`.', '',
              '## Конфигурация', '']
    if info.get('Name'): lines.append(f"- Имя метаданных: `{info['Name']}`")
    if info.get('Synonym'): lines.append(f"- Синоним: {info['Synonym']}")
    if info.get('Vendor'): lines.append(f"- Поставщик: {info['Vendor']}")
    if info.get('Version'): lines.append(f"- Редакция / версия: {info['Version']}")
    typ = 'расширение конфигурации (CFE)' if info.get('IsExtension') else 'основная конфигурация (CF)'
    lines.append(f"- Тип: {typ}")
    if info.get('NamePrefix'): lines.append(f"- Префикс расширения (NamePrefix): `{info['NamePrefix']}`")
    if info.get('Description'): lines += ['', info['Description']]
    lines += ['', '## Платформа', '']
    if info.get('PlatformVersion'): lines.append(f"- Совместимость: 1С:Предприятие {info['PlatformVersion']}")
    else: lines.append('- Совместимость: не определена в `Configuration.xml`')
    if info.get('DefaultRunMode'): lines.append(f"- Режим запуска по умолчанию: `{info['DefaultRunMode']}`")
    fm = info.get('FormMode', '')
    if fm:
        fm_text = {'managed':'управляемые','ordinary':'обычные','mixed':'смешанный (управляемые и обычные)'}.get(fm, fm)
        lines.append(f"- Режим форм: {fm_text}")
    if info.get('ScriptVariant'): lines.append(f"- Вариант встроенного языка: {info['ScriptVariant']}")
    lines += ['', '## Стандартная библиотека (БСП)', '']
    if info.get('BspDetected'):
        ver = info.get('BspVersion') or 'версия не определена'
        lines += ['- Используется: да', f'- Версия: {ver}']
    else:
        lines.append('- Используется: нет (общий модуль `СтандартныеПодсистемыСервер` не обнаружен)')
    lines.append('')
    subs = info.get('Subsystems', [])
    if subs:
        lines += [f"## Подсистемы верхнего уровня ({len(subs)})", '']
        lines += [f"- {s}" for s in subs]
        lines.append('')
    counts = info.get('Counts', {})
    if counts:
        lines += ['## Состав метаданных', '']
        lines += [f"- {k}: {v}" for k, v in counts.items()]
        lines.append('')
    lines += ['## Соглашения и ограничения', '',
              '- Язык платформы: 1С (BSL); комментарии и UI-строки — на русском',
              '- Стандарты ИТС, расширенные правилами проекта (см. `AGENTS.md` и каталог on-demand правил активного инструмента)',
              '- Запрет на тернарный оператор `?(...)`, `Сообщить()`, обращение к реквизитам через точку',
              '- Перед написанием кода — поиск по `templatesearch` / `codesearch` / `search_code`',
              '- После написания кода — `syntaxcheck` → `check_1c_code` → `review_1c_code` (≤ 3 раза за цикл)',
              '- Полный список запретов и стандартов — `AGENTS.md`, раздел *Forbidden Calls and Constructs*']
    return '\n'.join(lines) + '\n'

# ---- JSON manifest ----------------------------------------------------------

def read_manifest(root, manifest_name):
    path = os.path.join(root, manifest_name)
    if not os.path.isfile(path): return None
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f, object_pairs_hook=OrderedDict)

def write_manifest(root, manifest_name, manifest):
    path = os.path.join(root, manifest_name)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write('\n')

def new_manifest(source, version, protocol, channel):
    ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    return OrderedDict([
        ('protocol', protocol), ('source', source), ('version', version),
        ('installedAt', ts), ('updatedAt', ts), ('lastChannel', channel),
        ('tools', []), ('language', 'en'), ('mcpServers', []),
        ('files', OrderedDict()), ('foreignFiles', OrderedDict()), ('integrations', OrderedDict())
    ])

# ---- Dispatch: mode-specific logic ------------------------------------------

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else ''

    if mode == 'parse_adapter':
        path = sys.argv[2]
        print(json.dumps(parse_adapter_yaml(path), ensure_ascii=False))

    elif mode == 'split_frontmatter':
        text = sys.stdin.read()
        fm, body = split_frontmatter_body(text)
        print(json.dumps({'frontmatter': fm, 'body': body}, ensure_ascii=False))

    elif mode == 'apply_fm_ops':
        data = json.loads(sys.stdin.read(), object_pairs_hook=OrderedDict)
        result = apply_frontmatter_ops(data.get('source'), data.get('ops'))
        print(json.dumps(result, ensure_ascii=False))

    elif mode == 'format_frontmatter':
        fm = json.loads(sys.stdin.read(), object_pairs_hook=OrderedDict)
        print(format_frontmatter(fm))

    elif mode == 'codex_template':
        data = json.loads(sys.stdin.read(), object_pairs_hook=OrderedDict)
        print(codex_agent_template(data['template'], data['fm'], data['body']))

    elif mode == 'mcp_config':
        tool_id = sys.argv[2]
        servers = json.loads(sys.stdin.read())
        print(mcp_config(tool_id, servers))

    elif mode == 'merge_json_key':
        existing_path = sys.argv[2]
        merge_key = sys.argv[3]
        rendered = sys.stdin.read()
        result = merge_json_key(existing_path, rendered, merge_key)
        print(result if result is not None else '__PARSE_FAILED__')

    elif mode == 'read_manifest':
        root = sys.argv[2]
        mf_name = sys.argv[3]
        m = read_manifest(root, mf_name)
        print(json.dumps(m, ensure_ascii=False) if m else 'null')

    elif mode == 'write_manifest':
        root = sys.argv[2]
        mf_name = sys.argv[3]
        manifest = json.loads(sys.stdin.read(), object_pairs_hook=OrderedDict)
        write_manifest(root, mf_name, manifest)

    elif mode == 'new_manifest':
        d = json.loads(sys.stdin.read())
        m = new_manifest(d['source'], d['version'], d['protocol'], d['channel'])
        print(json.dumps(m, ensure_ascii=False))

    elif mode == 'detect_1c':
        root = sys.argv[2]
        info = detect_1c_project(root)
        print(json.dumps(info, ensure_ascii=False))

    elif mode == 'format_1c_md':
        info = json.loads(sys.stdin.read(), object_pairs_hook=OrderedDict)
        sys.stdout.write(format_1c_project_md(info))

    elif mode == 'manifest_get':
        # manifest_get <root> <mf_name> <jq_path>
        root, mf_name, jpath = sys.argv[2], sys.argv[3], sys.argv[4]
        m = read_manifest(root, mf_name)
        if m is None: print('null'); sys.exit(0)
        parts = jpath.lstrip('.').split('.')
        cur = m
        for p in parts:
            if isinstance(cur, dict) and p in cur: cur = cur[p]
            else: cur = None; break
        print(json.dumps(cur, ensure_ascii=False))

    elif mode == 'string_sha256':
        s = sys.argv[2]
        print(hashlib.sha256(s.encode('utf-8')).hexdigest())

    elif mode == 'read_mcp_servers':
        path = sys.argv[2]
        with open(path, 'r', encoding='utf-8') as f:
            obj = json.load(f)
        print(json.dumps(obj.get('servers', []), ensure_ascii=False))

    elif mode == 'json_patch':
        # Apply a set of JSON patch ops to manifest on stdin, write back
        # ops arrive as a second JSON doc in argv[2]
        manifest = json.loads(sys.stdin.read(), object_pairs_hook=OrderedDict)
        ops = json.loads(sys.argv[2])
        def deep_set(obj, path_parts, value):
            for p in path_parts[:-1]:
                if p not in obj: obj[p] = OrderedDict()
                obj = obj[p]
            obj[path_parts[-1]] = value
        for op in ops:
            if op['op'] == 'set':
                deep_set(manifest, op['path'], op['value'])
            elif op['op'] == 'append':
                arr = manifest
                for p in op['path'][:-1]: arr = arr[p]
                lst = arr.get(op['path'][-1], [])
                if op['value'] not in lst: lst.append(op['value'])
                arr[op['path'][-1]] = lst
            elif op['op'] == 'del_key':
                obj = manifest
                for p in op['path'][:-1]: obj = obj[p]
                obj.pop(op['path'][-1], None)
            elif op['op'] == 'set_file_entry':
                manifest['files'][op['rel']] = OrderedDict(op['entry'])
            elif op['op'] == 'del_file_entry':
                manifest['files'].pop(op['rel'], None)
            elif op['op'] == 'mark_user_modified':
                if op['rel'] in manifest['files']:
                    manifest['files'][op['rel']]['userModified'] = True
        print(json.dumps(manifest, ensure_ascii=False))

    elif mode == 'scan_integrations':
        root = sys.argv[2]
        result = OrderedDict()
        specs_dir = os.path.join(root, 'openspec', 'specs')
        changes_dir = os.path.join(root, 'openspec', 'changes')
        if os.path.isdir(specs_dir) or os.path.isdir(changes_dir):
            files = []
            for d in [specs_dir, changes_dir]:
                if os.path.isdir(d):
                    for rroot, rdirs, rfiles in os.walk(d):
                        for rf in rfiles:
                            if rf.endswith('.md'):
                                full = os.path.join(rroot, rf)
                                rel = os.path.relpath(full, root).replace('\\', '/')
                                files.append(rel)
            result['openspec'] = OrderedDict([('detected', True), ('files', sorted(files))])
        print(json.dumps(result, ensure_ascii=False))

    elif mode == 'scan_foreign':
        import sys
        data = json.loads(sys.stdin.read())
        root = data['root']
        active_tools = data['activeTools']
        managed_files = set(data.get('managedFiles', []))
        adapters = data['adapters']
        result = OrderedDict()
        root_real = os.path.realpath(root)
        for tool in active_tools:
            adapter = adapters.get(tool, {})
            dirs = []
            for section in ('rules', 'agents', 'commands', 'skills'):
                s = adapter.get(section, {})
                if isinstance(s, dict) and s.get('copyTo'):
                    tpl = s['copyTo']
                    d = re.sub(r'\{name\}.*$', '', tpl).rstrip('/')
                    if d: dirs.append(d)
            foreign = []
            for d in dirs:
                abs_d = os.path.join(root, d)
                if not os.path.isdir(abs_d): continue
                for rroot, rdirs, rfiles in os.walk(abs_d):
                    for rf in rfiles:
                        full = os.path.join(rroot, rf)
                        rel = os.path.relpath(full, root).replace('\\', '/')
                        if rel not in managed_files:
                            foreign.append(rel)
            result[tool] = sorted(set(foreign))
        print(json.dumps(result, ensure_ascii=False))

PYEOF
trap 'rm -f "$_py3_engine_file"' EXIT

# Helper: call the Python3 engine
_py3() {
    python3 "$_py3_engine_file" "$@"
}

# ============================================================================
# SECTION 6: YAML/JSON WRAPPER FUNCTIONS
# ============================================================================

py_parse_adapter() {
    _py3 parse_adapter "$1"
}

py_split_frontmatter() {
    # stdin: file content; stdout: JSON {"frontmatter":..., "body":...}
    _py3 split_frontmatter
}

py_apply_fm_ops() {
    # stdin: JSON {"source":..., "ops":...}; stdout: JSON
    _py3 apply_fm_ops
}

py_format_frontmatter() {
    # stdin: JSON dict; stdout: YAML frontmatter block
    _py3 format_frontmatter
}

py_codex_template() {
    # stdin: JSON {"template":..., "fm":..., "body":...}
    _py3 codex_template
}

py_mcp_config() {
    # $1: tool_id; stdin: JSON array of servers
    _py3 mcp_config "$1"
}

py_merge_json_key() {
    # $1: existing file path; $2: merge key; stdin: rendered JSON string
    # Prints merged JSON, or the literal '__PARSE_FAILED__' if the existing
    # file could not be parsed (caller falls back to overwriting).
    _py3 merge_json_key "$1" "$2"
}

py_read_manifest() {
    _py3 read_manifest "$1" "$MANIFEST_FILE_NAME"
}

py_write_manifest() {
    # stdin: JSON manifest
    _py3 write_manifest "$1" "$MANIFEST_FILE_NAME"
}

py_new_manifest() {
    # stdin: JSON {"source":..,"version":..,"protocol":..,"channel":..}
    _py3 new_manifest
}

py_manifest_get() {
    # $1: root $2: jq-style path like .tools
    _py3 manifest_get "$1" "$MANIFEST_FILE_NAME" "$2"
}

py_json_patch() {
    # stdin: manifest JSON; $1: ops JSON array
    _py3 json_patch "$1"
}

py_string_sha256() {
    _py3 string_sha256 "$1"
}

py_read_mcp_servers() {
    _py3 read_mcp_servers "$1"
}

py_scan_integrations() {
    _py3 scan_integrations "$1"
}

py_scan_foreign() {
    # stdin: JSON
    _py3 scan_foreign
}

py_detect_1c() {
    _py3 detect_1c "$1"
}

py_format_1c_md() {
    # stdin: JSON info
    _py3 format_1c_md
}

# ============================================================================
# SECTION 7: MANIFEST HELPERS (bash wrappers)
# ============================================================================

manifest_read() {
    # $1: root; echos JSON or 'null'
    py_read_manifest "$1"
}

manifest_write() {
    # $1: root; stdin: JSON
    py_write_manifest "$1"
}

manifest_exists() {
    [[ -f "$1/$MANIFEST_FILE_NAME" ]]
}

# Apply JSON patch ops to manifest file
# $1: root; $2: ops JSON array (written to file in place)
manifest_patch() {
    local root="$1"
    local ops="$2"
    local mf="$root/$MANIFEST_FILE_NAME"
    local new_content
    new_content="$(cat "$mf" | py_json_patch "$ops")"
    printf '%s\n' "$new_content" > "$mf"
}

# ============================================================================
# SECTION 8: SOURCE ROOT RESOLUTION
# ============================================================================

source_is_url() {
    local v="$1"
    [[ "$v" =~ ^(https?|git|ssh):// ]] && return 0
    [[ "$v" =~ ^git@[^:]+:.+ ]] && return 0
    [[ "$v" =~ \.git/?$ ]] && return 0
    return 1
}

get_source_from_url() {
    local url="$1"
    if ! command -v git &>/dev/null; then
        write_err "Source is a URL ($url) but 'git' was not found in PATH."
        exit 1
    fi
    local hash
    hash="$(py_string_sha256 "$url" | cut -c1-12)"
    local cache_dir="${TMPDIR:-/tmp}/1c-rules-source-$hash"
    if [[ -d "$cache_dir/.git" ]]; then
        write_info "Refreshing cached source: $cache_dir"
        if git -C "$cache_dir" fetch --depth 1 origin HEAD 2>/dev/null; then
            git -C "$cache_dir" reset --hard FETCH_HEAD 2>/dev/null || \
                write_warn "Reset failed; reusing existing cached checkout."
        else
            write_warn "Fetch failed; reusing existing cached checkout."
        fi
    else
        [[ -d "$cache_dir" ]] && rm -rf "$cache_dir"
        write_info "Cloning source: $url -> $cache_dir"
        if ! git clone --depth 1 "$url" "$cache_dir" 2>/dev/null; then
            write_err "git clone failed for $url"
            exit 1
        fi
    fi
    echo "$cache_dir"
}

resolve_source_root() {
    local requested="$1"
    if [[ -n "$requested" ]]; then
        if source_is_url "$requested"; then
            get_source_from_url "$requested"
            return
        fi
        if [[ -d "$requested" ]]; then
            echo "$(cd "$requested" && pwd)"
            return
        fi
        write_err "Source path does not exist: $requested"
        exit 1
    fi
    # Default: directory where install.sh lives
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$script_dir"
}

get_source_version() {
    local source_root="$1"
    if [[ -d "$source_root/.git" ]]; then
        local ver
        ver="$(git -C "$source_root" describe --tags --always 2>/dev/null || true)"
        [[ -n "$ver" ]] && echo "${ver}" && return
    fi
    echo "local"
}

# ============================================================================
# SECTION 9: TOOL DETECTION
# ============================================================================

get_tool_detection_signals() {
    local root="$1"
    local detected=()
    [[ -d "$root/.cursor" ]] && detected+=('cursor')
    [[ -d "$root/.claude" || -f "$root/CLAUDE.md" ]] && detected+=('claude-code')
    [[ -d "$root/.codex" ]] && detected+=('codex')
    [[ -d "$root/.opencode" || -f "$root/opencode.json" ]] && detected+=('opencode')
    [[ -d "$root/.kilo" || -d "$root/.kilocode" ]] && detected+=('kilocode')
    [[ -d "$root/.kimi-code" || -d "$root/.kimi" ]] && detected+=('kimi')
    [[ -d "$root/.qwen" || -f "$root/QWEN.md" ]] && detected+=('qwen')
    [[ -d "$root/.commandcode" ]] && detected+=('command-code')
    [[ -d "$root/.cline" || -d "$root/.clinerules" ]] && detected+=('cline')
    [[ -d "$root/.pi" ]] && detected+=('pi')
    # 'other' is a manual-only fallback — never auto-detected.
    echo "${detected[@]:-}"
}

invoke_detection() {
    local root="$1"
    local requested_tools="$2"  # space-separated

    if [[ -n "$requested_tools" ]]; then
        # Validate
        for t in $requested_tools; do
            local found=0
            for st in $SUPPORTED_TOOLS; do [[ "$t" == "$st" ]] && found=1 && break; done
            if [[ $found -eq 0 ]]; then
                write_err "Unknown tool id: $t. Supported: $SUPPORTED_TOOLS"
                exit 1
            fi
        done
        echo "$requested_tools"
        return
    fi

    local detected
    detected="$(get_tool_detection_signals "$root")"

    local det_count
    det_count=$(echo $detected | wc -w | tr -d ' ')

    if [[ "$det_count" -eq 1 ]]; then
        write_info "Detected tool: $detected (auto-selected)"
        echo "$detected"
        return
    fi

    if [[ "$det_count" -eq 0 ]]; then
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            write_err "No tools detected and no --tools provided. Refusing to guess in non-interactive mode."
            exit 1
        fi
        write_info "No AI tool directories detected in this project."
        write_info "Supported tools: $SUPPORTED_TOOLS"
        local ans
        read -r -p "Enter comma-separated tool ids to install for: " ans
        local list
        list="$(echo "$ans" | tr ',' ' ' | tr -s ' ')"
        [[ -z "$list" ]] && write_err "No tools selected; aborting." && exit 1
        echo "$list"
        return
    fi

    write_info "Detected tools: $detected"
    if [[ "$NON_INTERACTIVE" -eq 1 || "$ASSUME_YES" -eq 1 ]]; then
        echo "$detected"
        return
    fi
    local ans
    read -r -p "Press Enter to accept all, or enter comma-separated subset: " ans
    if [[ -z "$ans" ]]; then
        echo "$detected"
        return
    fi
    echo "$ans" | tr ',' ' ' | tr -s ' '
}

# ============================================================================
# SECTION 10: PLACE PHASE
# ============================================================================

resolve_copyto_path() {
    local tpl="$1"
    local name="$2"
    local result
    result="${tpl//\{name\}/$name}"
    if [[ "$result" == ~/* ]]; then
        result="$HOME/${result:2}"
    fi
    echo "$result"
}

# Place a single content file with frontmatter ops
# Args: root source_path target_rel fm_json body mode template manifest_json content_source
# Returns: new manifest_json (stdout)
place_artifact_file() {
    local root="$1"
    local source_path="$2"
    local target_rel="$3"
    local fm_json="$4"
    local body="$5"
    local mode="$6"
    local template="$7"
    local manifest_file="$root/$MANIFEST_FILE_NAME"
    local content_source="$8"

    # Check userModified
    local is_user_modified
    is_user_modified="$(python3 - "$manifest_file" "$target_rel" <<'PY' 2>/dev/null || echo '0'
import json,sys
with open(sys.argv[1], encoding='utf-8') as f:
    m=json.load(f)
e=m.get('files', {}).get(sys.argv[2], {})
print('1' if e.get('userModified') else '0')
PY
)"
    [[ "$is_user_modified" == '1' ]] && return

    # Determine absolute target path
    local abs_target
    if [[ "$target_rel" = /* || "$target_rel" = ~* ]]; then
        # Absolute or home-relative path
        if [[ "$target_rel" = ~* ]]; then
            abs_target="$HOME/${target_rel:2}"
        else
            abs_target="$target_rel"
        fi
    else
        abs_target="$root/$target_rel"
    fi

    local parent_dir
    parent_dir="$(dirname "$abs_target")"
    [[ ! -d "$parent_dir" ]] && mkdir -p "$parent_dir"

    if [[ "$mode" == 'rebuild-toml' ]]; then
        local rendered
        local template_json body_json payload_json
        template_json="$(printf '%s' "$template" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
        body_json="$(printf '%s' "$body" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
        payload_json="{\"template\":$template_json,\"fm\":$fm_json,\"body\":$body_json}"
        rendered="$(printf '%s' "$payload_json" | py_codex_template)"
        printf '%s' "$rendered" > "$abs_target"
    elif [[ "$mode" == 'verbatim' ]]; then
        cp -f "$source_path" "$abs_target"
    else
        # transform mode: apply frontmatter ops then write
        local ops_json
        ops_json="$(python3 - <<'PY' 2>/dev/null || echo 'null'
print('null')
PY
)"

        local new_fm
        new_fm="$(printf '%s' "{\"source\":$fm_json,\"ops\":null}" | py_apply_fm_ops)"
        local fm_text
        fm_text="$(printf '%s' "$new_fm" | py_format_frontmatter)"
        local full_content
        if [[ -n "$fm_text" ]]; then
            full_content="${fm_text}
${body}"
        else
            full_content="$body"
        fi
        printf '%s' "$full_content" > "$abs_target"
    fi

    local hash
    hash="$(file_sha256 "$abs_target")"
    # Update manifest
    manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$target_rel\",\"entry\":{\"source\":\"$content_source\",\"installedHash\":\"$hash\"}}]"
}

# Simplified place_artifact_file that reads source file directly (more reliable)
place_content_file() {
    local root="$1"
    local source_path="$2"
    local target_rel="$3"
    local mode="${4:-transform}"
    local template="${5:-}"
    local fm_ops_json="${6:-null}"
    local content_source="$7"

    # Check userModified
    local mf="$root/$MANIFEST_FILE_NAME"
    local is_user_modified=0
    if [[ -f "$mf" ]]; then
        is_user_modified="$(python3 -c "
import json
with open('$mf') as f: m=json.load(f)
e=m.get('files',{}).get('$target_rel',{})
print('1' if e.get('userModified') else '0')
" 2>/dev/null || echo '0')"
    fi
    [[ "$is_user_modified" == '1' ]] && return

    local abs_target
    if [[ "$target_rel" = /* ]]; then
        abs_target="$target_rel"
    elif [[ "$target_rel" = ~/* ]]; then
        abs_target="$HOME/${target_rel:2}"
    else
        abs_target="$root/$target_rel"
    fi

    local parent_dir
    parent_dir="$(dirname "$abs_target")"
    [[ ! -d "$parent_dir" ]] && mkdir -p "$parent_dir"

    if [[ "$mode" == 'verbatim' ]]; then
        cp -f "$source_path" "$abs_target"
    elif [[ "$mode" == 'rebuild-toml' ]]; then
        local content
        content="$(read_text_file "$source_path")"
        local parsed
        parsed="$(printf '%s' "$content" | py_split_frontmatter)"
        local fm_json body
        fm_json="$(printf '%s' "$parsed" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['frontmatter']))")"
        body="$(printf '%s' "$parsed" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['body'])")"
        local rendered
        local template_json body_json payload_json
        template_json="$(printf '%s' "$template" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
        body_json="$(printf '%s' "$body" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
        payload_json="{\"template\":$template_json,\"fm\":$fm_json,\"body\":$body_json}"
        rendered="$(printf '%s' "$payload_json" | py_codex_template)"
        printf '%s' "$rendered" > "$abs_target"
    else
        # transform: parse frontmatter, apply ops, re-serialize
        local content
        content="$(read_text_file "$source_path")"
        local parsed
        parsed="$(printf '%s' "$content" | py_split_frontmatter)"
        local fm_json body
        fm_json="$(printf '%s' "$parsed" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['frontmatter']))")"
        body="$(printf '%s' "$parsed" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['body'], end='')")"
        local new_fm
        new_fm="$(printf '%s' "{\"source\":$fm_json,\"ops\":$fm_ops_json}" | py_apply_fm_ops)"
        local fm_text
        fm_text="$(printf '%s' "$new_fm" | py_format_frontmatter)"
        if [[ -n "$fm_text" && "$fm_text" != $'---\n---' ]]; then
            printf '%s\n%s' "$fm_text" "$body" > "$abs_target"
        else
            printf '%s' "$body" > "$abs_target"
        fi
    fi

    local hash
    hash="$(file_sha256 "$abs_target")"
    manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$target_rel\",\"entry\":{\"source\":\"$content_source\",\"installedHash\":\"$hash\"}}]"
}

place_skill_dir() {
    local root="$1"
    local source_dir="$2"
    local target_dir="$3"
    local content_source="$4"

    local abs_target="$root/$target_dir"
    [[ -d "$abs_target" ]] && rm -rf "$abs_target"
    mkdir -p "$(dirname "$abs_target")"
    cp -r "$source_dir" "$abs_target"

    # Register all files
    local ops_json='['
    local first=1
    while IFS= read -r -d '' f; do
        local rel
        rel="$(python3 -c "import os; print(os.path.relpath('$f', '$root').replace(chr(92), '/'))")"
        local hash
        hash="$(file_sha256 "$f")"
        [[ $first -eq 0 ]] && ops_json+=','
        ops_json+="{\"op\":\"set_file_entry\",\"rel\":\"$rel\",\"entry\":{\"source\":\"$content_source\",\"installedHash\":\"$hash\"}}"
        first=0
    done < <(find "$abs_target" -type f -print0)
    ops_json+=']'
    manifest_patch "$root" "$ops_json"
}

invoke_place_phase() {
    local root="$1"
    local source_root="$2"
    local active_tools="$3"  # space-separated

    for tool in $active_tools; do
        write_info "  [$tool] placing files"
        local adapter_json
        adapter_json="$(py_parse_adapter "$source_root/adapters/$tool.yaml")"

        # Helper to get string field from adapter JSON
        adapter_get() { printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('$1',{}); print(json.dumps(v) if isinstance(v,dict) else (v or ''))" 2>/dev/null || echo ''; }
        adapter_str() { printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('$1',{}).get('$2',''); print(v or '')" 2>/dev/null || echo ''; }

        # rules
        local rules_copy_to
        rules_copy_to="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('rules',{}).get('copyTo',''))" 2>/dev/null || echo '')"
        if [[ -n "$rules_copy_to" ]]; then
            local rules_mode rules_fm_ops
            rules_mode="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('rules',{}).get('mode','transform'))" 2>/dev/null || echo 'transform')"
            rules_fm_ops="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('rules',{}).get('frontmatter')))" 2>/dev/null || echo 'null')"
            local rules_dir="$source_root/content/rules"
            if [[ -d "$rules_dir" ]]; then
                while IFS= read -r f; do
                    local name
                    name="$(basename "${f%.md}")"
                    local target
                    target="$(resolve_copyto_path "$rules_copy_to" "$name")"
                    place_content_file "$root" "$f" "$target" "$rules_mode" '' "$rules_fm_ops" "content/rules/$(basename "$f")"
                done < <(find "$rules_dir" -maxdepth 1 -name '*.md' -type f)
            fi
        fi

        # agents
        local agents_copy_to
        agents_copy_to="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agents',{}).get('copyTo',''))" 2>/dev/null || echo '')"
        if [[ -n "$agents_copy_to" ]]; then
            local agents_mode agents_fm_ops agents_template
            agents_mode="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agents',{}).get('mode','transform'))" 2>/dev/null || echo 'transform')"
            agents_fm_ops="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('agents',{}).get('frontmatter')))" 2>/dev/null || echo 'null')"
            agents_template="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agents',{}).get('template',''))" 2>/dev/null || echo '')"
            local agents_dir="$source_root/content/agents"
            if [[ -d "$agents_dir" ]]; then
                while IFS= read -r f; do
                    local name
                    name="$(basename "${f%.md}")"
                    local target
                    target="$(resolve_copyto_path "$agents_copy_to" "$name")"
                    place_content_file "$root" "$f" "$target" "$agents_mode" "$agents_template" "$agents_fm_ops" "content/agents/$(basename "$f")"
                done < <(find "$agents_dir" -maxdepth 1 -name '*.md' -type f)
            fi
        fi

        # commands
        local commands_copy_to
        commands_copy_to="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('commands',{}).get('copyTo',''))" 2>/dev/null || echo '')"
        if [[ -n "$commands_copy_to" ]]; then
            local cmds_mode cmds_fm_ops
            cmds_mode="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('commands',{}).get('mode','transform'))" 2>/dev/null || echo 'transform')"
            cmds_fm_ops="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('commands',{}).get('frontmatter')))" 2>/dev/null || echo 'null')"
            local cmds_dir="$source_root/content/commands"
            if [[ -d "$cmds_dir" ]]; then
                while IFS= read -r f; do
                    local name
                    name="$(basename "${f%.md}")"
                    local target
                    target="$(resolve_copyto_path "$commands_copy_to" "$name")"
                    if [[ "$commands_copy_to" == ~/* ]]; then
                        place_content_file "$root" "$f" "$target" "$cmds_mode" '' "$cmds_fm_ops" "content/commands/$(basename "$f")"
                        write_warn "  command written to user scope: $target (shared across projects)"
                    else
                        place_content_file "$root" "$f" "$target" "$cmds_mode" '' "$cmds_fm_ops" "content/commands/$(basename "$f")"
                    fi
                done < <(find "$cmds_dir" -maxdepth 1 -name '*.md' -type f)
            fi
        fi

        # skills
        local skills_copy_to
        skills_copy_to="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('skills',{}).get('copyTo','').rstrip('/'))" 2>/dev/null || echo '')"
        if [[ -n "$skills_copy_to" ]]; then
            local skills_dir="$source_root/content/skills"
            if [[ -d "$skills_dir" ]]; then
                while IFS= read -r skill_dir; do
                    local skill_name
                    skill_name="$(basename "$skill_dir")"
                    [[ ! -f "$skill_dir/SKILL.md" ]] && continue
                    local target_dir
                    target_dir="$(resolve_copyto_path "$skills_copy_to" "$skill_name")"
                    place_skill_dir "$root" "$skill_dir" "$target_dir" "content/skills/$skill_name"
                done < <(find "$skills_dir" -maxdepth 1 -mindepth 1 -type d)
            fi
        fi

        # entry (e.g. CLAUDE.md)
        local entry_target entry_template
        entry_target="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('entry',{}).get('target',''))" 2>/dev/null || echo '')"
        entry_template="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('entry',{}).get('template',''))" 2>/dev/null || echo '')"
        if [[ -n "$entry_target" && -n "$entry_template" ]]; then
            local abs_entry="$root/$entry_target"
            mkdir -p "$(dirname "$abs_entry")"
            printf '%s' "$entry_template" > "$abs_entry"
            local hash
            hash="$(file_sha256 "$abs_entry")"
            manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$entry_target\",\"entry\":{\"source\":\"adapters/$tool.yaml#entry\",\"installedHash\":\"$hash\"}}]"
        fi
    done
}

# ============================================================================
# SECTION 11: MCP PHASE
# ============================================================================

invoke_mcp_phase() {
    local root="$1"
    local source_root="$2"
    local active_tools="$3"

    local mcp_servers_file="$source_root/content/mcp-servers.json"
    if [[ ! -f "$mcp_servers_file" ]]; then
        write_warn "MCP servers list not found: $mcp_servers_file — skipping MCP phase"
        return
    fi

    local servers_json
    servers_json="$(py_read_mcp_servers "$mcp_servers_file")"
    local installed_ids
    installed_ids="$(printf '%s' "$servers_json" | python3 -c "import json,sys; s=json.load(sys.stdin); print(json.dumps([x['id'] for x in s]))")"

    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"mcpServers\"],\"value\":$installed_ids}]"

    for tool in $active_tools; do
        local adapter_json
        adapter_json="$(py_parse_adapter "$source_root/adapters/$tool.yaml")"
        local mcp_target
        mcp_target="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mcp',{}).get('target',''))" 2>/dev/null || echo '')"
        [[ -z "$mcp_target" ]] && continue

        local abs_target="$root/$mcp_target"
        mkdir -p "$(dirname "$abs_target")"
        local content
        content="$(printf '%s' "$servers_json" | py_mcp_config "$tool")"

        # `mcp.merge: true` (adapter yaml) — the target file is a SHARED
        # tool config (`.kilo/kilo.json`, `opencode.json`,
        # `.qwen/settings.json` also carry instructions / permissions /
        # model settings). Deep-merge only the top-level merge key (default
        # `mcp`, overridable via `mcp.mergeKey`) instead of overwriting the
        # whole file, so user keys survive `update`.
        local mcp_merge mcp_merge_key
        mcp_merge="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if d.get('mcp',{}).get('merge') else '0')" 2>/dev/null || echo '0')"
        mcp_merge_key="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mcp',{}).get('mergeKey') or 'mcp')" 2>/dev/null || echo 'mcp')"
        if [[ "$mcp_merge" == '1' && -f "$abs_target" ]]; then
            local merged
            merged="$(printf '%s' "$content" | py_merge_json_key "$abs_target" "$mcp_merge_key")"
            if [[ "$merged" == '__PARSE_FAILED__' ]]; then
                write_info "  [$tool] MCP merge: existing $mcp_target не парсится как JSON — перезаписываю."
            else
                content="$merged"
            fi
        fi

        printf '%s\n' "$content" > "$abs_target"
        local hash
        hash="$(file_sha256 "$abs_target")"
        manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$mcp_target\",\"entry\":{\"source\":\"content/mcp-servers.json\",\"installedHash\":\"$hash\"}}]"
        write_info "  [$tool] MCP config: $mcp_target"
    done
}

# ============================================================================
# SECTION 12: AGENTS.MD (STATIC COPY)
# ============================================================================

RULES_DIR_PRIORITY='cursor claude-code kilocode kimi qwen command-code cline opencode codex pi other'

resolve_canonical_rules_layout() {
    local active_tools="$1"
    local source_root="$2"
    # Returns "dir:ext" or empty
    for tool in $RULES_DIR_PRIORITY; do
        echo "$active_tools" | grep -qw "$tool" || continue
        local adapter_json
        adapter_json="$(py_parse_adapter "$source_root/adapters/$tool.yaml" 2>/dev/null || echo '{}')"
        local copy_to
        copy_to="$(printf '%s' "$adapter_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('rules',{}).get('copyTo',''))" 2>/dev/null || echo '')"
        [[ -z "$copy_to" ]] && continue
        local dir ext
        dir="$(python3 -c "import re; print(re.sub(r'\{name\}.*$','','$copy_to').rstrip('/'))")"
        ext="$(python3 -c "import re; m=re.search(r'\{name\}\.([A-Za-z0-9]+)$','$copy_to'); print(m.group(1) if m else '')")"
        [[ -n "$dir" ]] && echo "${dir}:${ext}" && return
    done
    echo ''
}

update_agents_md() {
    local root="$1"
    local source_root="$2"
    local active_tools="$3"

    local source_agents="$source_root/$AGENTS_MD_FILE_NAME"
    [[ ! -f "$source_agents" ]] && return

    local layout
    layout="$(resolve_canonical_rules_layout "$active_tools" "$source_root")"
    local rules_dir rules_ext
    if [[ -z "$layout" ]]; then
        write_warn "No active tool defines a rules directory; AGENTS.md placeholders will be left as-is."
        rules_dir='{{ rulesDir }}'
        rules_ext='{{ rulesExt }}'
    else
        rules_dir="${layout%%:*}"
        rules_ext="${layout##*:}"
        [[ -z "$rules_ext" ]] && rules_ext='md'
    fi

    local source_text
    source_text="$(read_text_file "$source_agents")"
    local rendered
    rendered="${source_text//\{\{ rulesDir \}\}/$rules_dir}"
    rendered="${rendered//\{\{ rulesExt \}\}/$rules_ext}"

    local agents_path="$root/$AGENTS_MD_FILE_NAME"
    local should_refresh=0
    if [[ ! -f "$agents_path" ]]; then
        should_refresh=1
    else
        local mf="$root/$MANIFEST_FILE_NAME"
        if [[ -f "$mf" ]]; then
            local entry_user_mod installed_hash
            entry_user_mod="$(python3 -c "import json; m=json.load(open('$mf')); e=m.get('files',{}).get('$AGENTS_MD_FILE_NAME',{}); print('1' if e.get('userModified') else '0')" 2>/dev/null || echo '0')"
            if [[ "$entry_user_mod" == '0' ]]; then
                installed_hash="$(python3 -c "import json; m=json.load(open('$mf')); print(m.get('files',{}).get('$AGENTS_MD_FILE_NAME',{}).get('installedHash',''))" 2>/dev/null || echo '')"
                local current_hash
                current_hash="$(file_sha256 "$agents_path")"
                [[ "$current_hash" == "$installed_hash" ]] && should_refresh=1
            fi
        else
            should_refresh=1
        fi
    fi

    [[ "$should_refresh" -eq 1 ]] && write_text_file "$agents_path" "$rendered"

    if [[ -f "$agents_path" ]]; then
        local hash
        hash="$(file_sha256 "$agents_path")"
        local rules_dir_escaped
        rules_dir_escaped="$(printf '%s' "$rules_dir" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
        manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$AGENTS_MD_FILE_NAME\",\"entry\":{\"source\":\"AGENTS.md\",\"rulesDir\":$rules_dir_escaped,\"rulesExt\":\"$rules_ext\",\"installedHash\":\"$hash\"}}]"
    fi
}

# ============================================================================
# SECTION 13: OPENSPEC
# ============================================================================

invoke_openspec_scaffold() {
    local root="$1"
    local source_root="$2"

    local source_openspec="$source_root/openspec"
    if [[ ! -d "$source_openspec" ]]; then
        write_warn "OpenSpec scaffold: source folder not found at $source_openspec — skipped."
        return
    fi

    local copied=0 skipped=0
    while IFS= read -r -d '' f; do
        local rel
        rel="$(python3 -c "import os; print(os.path.relpath('$f', '$source_openspec').replace(chr(92), '/'))")"
        local target="$root/openspec/$rel"
        if [[ -f "$target" ]]; then
            skipped=$((skipped + 1))
        else
            mkdir -p "$(dirname "$target")"
            cp "$f" "$target"
            copied=$((copied + 1))
        fi
    done < <(find "$source_openspec" -type f -print0)

    if [[ $((copied + skipped)) -gt 0 ]]; then
        write_info "  OpenSpec scaffold: $copied copied, $skipped skipped (existing files preserved)"
        manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"integrations\",\"openspec\",\"scaffolded\"],\"value\":true}]"
    fi
}

invoke_openspec_artifacts() {
    local root="$1"
    local source_root="$2"
    local active_tools="$3"

    local bundle_root="$source_root/content/openspec-bundle"
    if [[ ! -d "$bundle_root" ]]; then
        write_warn "OpenSpec artefacts: bundle not found at $bundle_root — skipped."
        return
    fi

    local total_copied=0
    for tool in $active_tools; do
        local tool_bundle="$bundle_root/$tool"
        [[ ! -d "$tool_bundle" ]] && continue

        local tool_copied=0
        while IFS= read -r -d '' f; do
            local rel target_rel
            rel="$(python3 -c "import os; print(os.path.relpath('$f', '$tool_bundle').replace(chr(92), '/'))")"
            target_rel="$rel"
            place_content_file "$root" "$f" "$target_rel" 'verbatim' '' 'null' "content/openspec-bundle/$tool/$rel"
            tool_copied=$((tool_copied + 1))
        done < <(find "$tool_bundle" -type f -print0)

        if [[ $tool_copied -gt 0 ]]; then
            write_info "  [$tool] OpenSpec artefacts: $tool_copied placed"
        fi
        total_copied=$((total_copied + tool_copied))
    done

    # Record openspec artefacts bundle version if present
    local bundle_version_file="$bundle_root/version.txt"
    if [[ -f "$bundle_version_file" ]]; then
        local bver
        bver="$(cat "$bundle_version_file" | tr -d '[:space:]')"
        manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"integrations\",\"openspec\",\"artifactsBundleVersion\"],\"value\":\"$bver\"}]"
        write_info "  OpenSpec artefacts: $total_copied placed (bundle v$bver)"
    else
        write_info "  OpenSpec artefacts: $total_copied placed"
    fi
}

invoke_openspec_project_md() {
    local root="$1"
    local rel='openspec/project.md'

    local info_json
    info_json="$(py_detect_1c "$root")"
    local detected
    detected="$(printf '%s' "$info_json" | python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('Detected') else '0')")"

    if [[ "$detected" != '1' ]]; then
        write_info "  OpenSpec project.md: 1С-сигналов не найдено (нет Configuration.xml) — пропуск"
        return
    fi

    # Check userModified
    local mf="$root/$MANIFEST_FILE_NAME"
    if [[ -f "$mf" ]]; then
        local user_mod
        user_mod="$(python3 -c "import json; m=json.load(open('$mf')); e=m.get('files',{}).get('$rel',{}); print('1' if e.get('userModified') else '0')" 2>/dev/null || echo '0')"
        if [[ "$user_mod" == '1' ]]; then
            write_info "  OpenSpec project.md: оставлен без изменений (userModified)"
            return
        fi
    fi

    local abs_target="$root/$rel"
    mkdir -p "$(dirname "$abs_target")"
    local content
    content="$(printf '%s' "$info_json" | py_format_1c_md)"
    printf '%s' "$content" > "$abs_target"
    local hash
    hash="$(file_sha256 "$abs_target")"
    manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$rel\",\"entry\":{\"source\":\"<auto-generated:1c-rules>\",\"installedHash\":\"$hash\"}}]"
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"integrations\",\"openspec\",\"projectMdGenerated\"],\"value\":true}]"

    local summary
    summary="$(python3 - "$info_json" <<'PY'
import json,sys
info=json.loads(sys.argv[1])
parts=[]
if info.get('Synonym'):
    parts.append(info['Synonym'])
elif info.get('Name'):
    parts.append(info['Name'])
if info.get('PlatformVersion'):
    parts.append('8.3.x: '+info['PlatformVersion'])
if info.get('BspDetected'):
    bsp='БСП'
    if info.get('BspVersion'):
        bsp+=' '+info['BspVersion']
    parts.append(bsp)
if info.get('FormMode'):
    parts.append('формы: '+info['FormMode'])
if info.get('IsExtension'):
    parts.append('CFE')
print(' | '.join(parts))
PY
)"
    write_info "  OpenSpec project.md: $summary"
}

# ============================================================================
# SECTION 14: ROOT TEMPLATES
# ============================================================================

place_root_templates() {
    local root="$1"
    local source_root="$2"

    for name in "$USER_RULES_FILE_NAME" "$MEMORY_FILE_NAME" "$LLM_RULES_FILE_NAME"; do
        local target="$root/$name"
        local source="$source_root/$name"
        if [[ -f "$target" ]]; then
            local mf="$root/$MANIFEST_FILE_NAME"
            if [[ -f "$mf" ]]; then
                local has_entry
                has_entry="$(python3 -c "import json; m=json.load(open('$mf')); print('1' if '$name' in m.get('files',{}) else '0')" 2>/dev/null || echo '0')"
                if [[ "$has_entry" == '0' ]]; then
                    local hash
                    hash="$(file_sha256 "$target")"
                    manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$name\",\"entry\":{\"source\":\"$name\",\"template\":true,\"installedHash\":\"$hash\"}}]"
                fi
            fi
            continue
        fi
        if [[ ! -f "$source" ]]; then
            write_warn "Template not found in source: $name"
            continue
        fi
        cp "$source" "$target"
        local hash
        hash="$(file_sha256 "$target")"
        manifest_patch "$root" "[{\"op\":\"set_file_entry\",\"rel\":\"$name\",\"entry\":{\"source\":\"$name\",\"template\":true,\"installedHash\":\"$hash\"}}]"
        write_info "  placed (template, will not be overwritten on update): $name"
    done
}

# ============================================================================
# SECTION 15: VERIFY
# ============================================================================

invoke_verify() {
    local root="$1"
    local mf="$root/$MANIFEST_FILE_NAME"
    [[ ! -f "$mf" ]] && echo '{"ok":true,"count":0,"mismatches":[]}' && return

    python3 - "$root" "$mf" <<'PY'
import json, os, hashlib, sys
def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()
root = sys.argv[1]
mf = sys.argv[2]
with open(mf, encoding='utf-8') as f:
    m = json.load(f)
mismatches = []
count = 0
for rel, entry in m.get('files', {}).items():
    abs_path = rel if os.path.isabs(rel) else os.path.join(root, rel)
    if rel.startswith('~/'):
        abs_path = os.path.expanduser(rel)
    if not os.path.isfile(abs_path):
        mismatches.append('missing: ' + rel)
        continue
    count += 1
    actual = file_sha256(abs_path)
    expected = entry.get('installedHash', '')
    if actual != expected:
        mismatches.append('hash diff: ' + rel)
print(json.dumps({'ok': len(mismatches) == 0, 'count': count, 'mismatches': mismatches}))
PY
}

# ============================================================================
# SECTION 16: COMMANDS
# ============================================================================

# ---- init -------------------------------------------------------------------

cmd_init() {
    local root="$1"
    local source_root_req="$2"
    local requested_tools="$3"  # space-separated

    write_section 'Phase 1: Detection'
    local source_root
    source_root="$(resolve_source_root "$source_root_req")"
    write_info "Source: $source_root"
    write_info "Project: $root"

    if manifest_exists "$root"; then
        if [[ "$ASSUME_YES" -eq 0 && "$NON_INTERACTIVE" -eq 0 ]]; then
            write_warn "Manifest already exists. init will overwrite it."
            read_yesno "Proceed with re-init?" 0 || return
        fi
    fi

    local active_tools
    active_tools="$(invoke_detection "$root" "$requested_tools")"
    write_info "Active tools: $active_tools"

    write_section 'Phase 2-3: Scan foreign files + integrations'
    local foreign_json
    foreign_json="$(invoke_scan_foreign_for_tools "$root" "$active_tools" "$source_root")"
    local integrations_json
    integrations_json="$(py_scan_integrations "$root")"

    # Report
    python3 - "$foreign_json" <<'PY' 2>/dev/null || true
import json,sys
f=json.loads(sys.argv[1])
for t,files in f.items():
    if files:
        print(f"  foreign[{t}]: {len(files)} file(s)")
PY
    python3 - "$integrations_json" <<'PY' 2>/dev/null || true
import json,sys
i=json.loads(sys.argv[1])
if 'openspec' in i:
    print(f"  integration: openspec ({len(i['openspec'].get('files',[]))} files)")
PY

    write_section 'Phase 4: Plan'
    write_info "Will write per-tool files into: .$(echo "$active_tools" | tr ' ' ',')"
    write_info "MCP servers will be added to each tool's MCP config."
    if [[ "$ASSUME_YES" -eq 0 && "$NON_INTERACTIVE" -eq 0 ]]; then
        read_yesno "Proceed with installation?" 1 || return
    fi

    local version
    version="$(get_source_version "$source_root")"

    # Create initial manifest
    local manifest_init_json
    manifest_init_json="$(printf '%s' "{\"source\":\"$source_root\",\"version\":\"$version\",\"protocol\":\"$PROTOCOL_VERSION\",\"channel\":\"$LAST_CHANNEL\"}" | py_new_manifest)"
    printf '%s\n' "$manifest_init_json" > "$root/$MANIFEST_FILE_NAME"

    # Set tools, foreignFiles, integrations
    local tools_arr
    tools_arr="$(echo "$active_tools" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().split()))")"
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"tools\"],\"value\":$tools_arr},{\"op\":\"set\",\"path\":[\"foreignFiles\"],\"value\":$foreign_json},{\"op\":\"set\",\"path\":[\"integrations\"],\"value\":$integrations_json}]"

    write_section 'Phase 6: Place (copy + transform)'
    invoke_place_phase "$root" "$source_root" "$active_tools"

    write_section 'Phase 6b: OpenSpec scaffold'
    invoke_openspec_scaffold "$root" "$source_root"
    local rescanned
    rescanned="$(py_scan_integrations "$root")"
    local was_scaffolded
    was_scaffolded="$(python3 -c "import json; m=json.load(open('$root/$MANIFEST_FILE_NAME')); print('True' if m.get('integrations',{}).get('openspec',{}).get('scaffolded') else 'False')" 2>/dev/null || echo 'False')"
    if python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if 'openspec' in d else 1)" <<< "$rescanned" 2>/dev/null; then
        rescanned="$(printf '%s' "$rescanned" | python3 -c "import json,sys; d=json.load(sys.stdin); d.setdefault('openspec',{})['scaffolded']=$was_scaffolded; print(json.dumps(d))")"
    fi
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"integrations\"],\"value\":$rescanned}]"

    write_section 'Phase 6c: OpenSpec artefacts'
    invoke_openspec_artifacts "$root" "$source_root" "$active_tools"

    write_section 'Phase 6d: OpenSpec project.md (1C autodetect)'
    invoke_openspec_project_md "$root"

    write_section 'Phase 7: MCP'
    invoke_mcp_phase "$root" "$source_root" "$active_tools"

    write_section 'Phase 8: AGENTS.md'
    update_agents_md "$root" "$source_root" "$active_tools"

    write_section 'Phase 8b: Root templates (USER-RULES.md, memory.md, LLM-RULES.md)'
    place_root_templates "$root" "$source_root"

    write_section 'Phase 9: Manifest'
    write_info ".ai-rules.json written"

    write_section 'Phase 10: Verify'
    local verify
    verify="$(invoke_verify "$root")"
    local v_ok v_count v_mismatches
    v_ok="$(printf '%s' "$verify" | python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if d['ok'] else '0')")"
    v_count="$(printf '%s' "$verify" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")"
    if [[ "$v_ok" == '1' ]]; then
        write_info "Verification OK: $v_count files checked"
    else
        printf '%s' "$verify" | python3 -c "import json,sys; d=json.load(sys.stdin); [print('  '+m) for m in d['mismatches']]"
    fi

    write_section 'Phase 11: Report'
    write_info "Installation complete."
    write_info "  Version: $version (via $LAST_CHANNEL channel)"
    write_info "  Tools: $active_tools"
    local file_count mcp_count
    file_count="$(python3 -c "import json; m=json.load(open('$root/$MANIFEST_FILE_NAME')); print(len(m.get('files',{})))")"
    mcp_count="$(python3 -c "import json; m=json.load(open('$root/$MANIFEST_FILE_NAME')); print(len(m.get('mcpServers',[])))")"
    write_info "  Files written: $file_count"
    write_info "  MCP servers: $mcp_count"
}

# ---- update -----------------------------------------------------------------

cmd_update() {
    local root="$1"
    local source_root_req="$2"

    if ! manifest_exists "$root"; then
        write_err "No manifest found. Run init first."
        exit 1
    fi

    local manifest_json
    manifest_json="$(manifest_read "$root")"

    # Protocol version check
    local stored_protocol
    stored_protocol="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('protocol','1.0'))")"
    if python3 -c "import sys; a,b=[int(x) for x in '$stored_protocol'.split('.')]; c,d=[int(x) for x in '$PROTOCOL_VERSION'.split('.')]; sys.exit(0 if (a>c or (a==c and b>d)) else 1)" 2>/dev/null; then
        write_err "Manifest protocol $stored_protocol is newer than installer $PROTOCOL_VERSION. Update installer first."
        exit 1
    fi

    local source_root
    source_root="$(resolve_source_root "$source_root_req")"
    write_info "Source: $source_root"

    local active_tools
    active_tools="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('tools',[])))")"

    # Migration: remove legacy .ai-rules/rules/ entries
    write_section 'Migration: legacy .ai-rules/rules/ mirror'
    local legacy_keys dirty_legacy
    legacy_keys="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); print('\n'.join(k for k in m.get('files',{}) if k.startswith('.ai-rules/rules/')))")"
    dirty_legacy=''
    if [[ -n "$legacy_keys" ]]; then
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            local abs="$root/$k"
            if [[ -f "$abs" ]]; then
                local expected actual
                expected="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('files',{}).get('$k',{}).get('installedHash',''))")"
                actual="$(file_sha256 "$abs")"
                [[ -n "$expected" && "$actual" != "$expected" ]] && dirty_legacy="$dirty_legacy $k"
            fi
        done <<< "$legacy_keys"
    fi

    local proceed_legacy=1
    if [[ -n "$dirty_legacy" ]]; then
        write_warn "Legacy .ai-rules/rules/ contains user-modified files:$(echo "$dirty_legacy" | tr ' ' '\n' | grep . | while read l; do echo "  $l"; done)"
        if [[ "$NON_INTERACTIVE" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
            read_yesno "Delete legacy .ai-rules/rules/ anyway? (your edits will be lost)" 0 || proceed_legacy=0
        fi
    fi
    if [[ "$proceed_legacy" -eq 1 && -n "$legacy_keys" ]]; then
        local del_ops='['
        local first=1
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            [[ -f "$root/$k" ]] && rm -f "$root/$k"
            [[ $first -eq 0 ]] && del_ops+=','
            del_ops+="{\"op\":\"del_file_entry\",\"rel\":\"$k\"}"
            first=0
        done <<< "$legacy_keys"
        del_ops+=']'
        manifest_patch "$root" "$del_ops"
        local legacy_dir="$root/.ai-rules/rules"
        if [[ -d "$legacy_dir" ]]; then
            local remaining
            remaining="$(find "$legacy_dir" -type f 2>/dev/null | head -1)"
            if [[ -z "$remaining" ]]; then
                rm -rf "$legacy_dir"
                local parent="$root/.ai-rules"
                [[ -d "$parent" && -z "$(ls -A "$parent" 2>/dev/null)" ]] && rm -rf "$parent"
            fi
        fi
        write_info "Migrated: removed legacy .ai-rules/rules/ entries"
    fi

    # Detect user-modified files
    write_section 'Detecting user-modified files'
    manifest_json="$(manifest_read "$root")"
    local dirty=()
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        local abs
        abs="$(python3 -c "import os; r='$rel'; print(os.path.expanduser(r) if r.startswith('~') else os.path.join('$root',r))")"
        [[ ! -f "$abs" ]] && continue
        local actual expected
        actual="$(file_sha256 "$abs")"
        expected="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('files',{}).get('$rel',{}).get('installedHash',''))")"
        [[ "$actual" != "$expected" ]] && dirty+=("$rel")
    done < <(printf '%s' "$manifest_json" | python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin).get('files',{})]")

    if [[ ${#dirty[@]} -gt 0 ]]; then
        write_warn "User-modified files detected: ${#dirty[@]}"
        for d in "${dirty[@]}"; do write_warn "  $d"; done
        if [[ "$NON_INTERACTIVE" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
            local choice
            choice="$(read_choice "Resolution" "keep take skip" "keep")"
            if [[ "$choice" != 'take' ]]; then
                local mark_ops='['
                local first=1
                for d in "${dirty[@]}"; do
                    [[ $first -eq 0 ]] && mark_ops+=','
                    mark_ops+="{\"op\":\"mark_user_modified\",\"rel\":\"$d\"}"
                    first=0
                done
                mark_ops+=']'
                manifest_patch "$root" "$mark_ops"
            fi
        else
            local mark_ops='['
            local first=1
            for d in "${dirty[@]}"; do
                [[ $first -eq 0 ]] && mark_ops+=','
                mark_ops+="{\"op\":\"mark_user_modified\",\"rel\":\"$d\"}"
                first=0
            done
            mark_ops+=']'
            manifest_patch "$root" "$mark_ops"
        fi
    fi

    # Rescan foreign + integrations
    local foreign_json integrations_json
    foreign_json="$(invoke_scan_foreign_for_tools "$root" "$active_tools" "$source_root")"
    integrations_json="$(py_scan_integrations "$root")"

    # Preserve only userModified entries, clear the rest
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"foreignFiles\"],\"value\":$foreign_json},{\"op\":\"set\",\"path\":[\"integrations\"],\"value\":$integrations_json}]"
    # Clear non-userModified file entries (they'll be re-written by place)
    python3 - "$root/$MANIFEST_FILE_NAME" <<'PY'
import json,sys
mf=sys.argv[1]
with open(mf, encoding='utf-8') as f:
    m=json.load(f)
m['files']={k:v for k,v in m.get('files',{}).items() if v.get('userModified')}
with open(mf, 'w', encoding='utf-8') as f:
    json.dump(m,f,indent=2,ensure_ascii=False)
    f.write('\n')
PY

    write_section 'Place (update)'
    invoke_place_phase "$root" "$source_root" "$active_tools"

    write_section 'OpenSpec scaffold (update)'
    invoke_openspec_scaffold "$root" "$source_root"
    local rescanned
    rescanned="$(py_scan_integrations "$root")"
    local was_scaffolded
    was_scaffolded="$(python3 -c "import json; m=json.load(open('$root/$MANIFEST_FILE_NAME')); print('True' if m.get('integrations',{}).get('openspec',{}).get('scaffolded') else 'False')" 2>/dev/null || echo 'False')"
    if python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if 'openspec' in d else 1)" <<< "$rescanned" 2>/dev/null; then
        rescanned="$(printf '%s' "$rescanned" | python3 -c "import json,sys; d=json.load(sys.stdin); d.setdefault('openspec',{})['scaffolded']=$was_scaffolded; print(json.dumps(d))")"
    fi
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"integrations\"],\"value\":$rescanned}]"

    write_section 'OpenSpec artefacts (update)'
    invoke_openspec_artifacts "$root" "$source_root" "$active_tools"

    write_section 'OpenSpec project.md (update / 1C autodetect)'
    invoke_openspec_project_md "$root"

    write_section 'MCP (update)'
    invoke_mcp_phase "$root" "$source_root" "$active_tools"

    write_section 'AGENTS.md (update)'
    update_agents_md "$root" "$source_root" "$active_tools"

    write_section 'Root templates (update)'
    place_root_templates "$root" "$source_root"

    local version
    version="$(get_source_version "$source_root")"
    local ts
    ts="$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")"
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"updatedAt\"],\"value\":\"$ts\"},{\"op\":\"set\",\"path\":[\"lastChannel\"],\"value\":\"$LAST_CHANNEL\"},{\"op\":\"set\",\"path\":[\"version\"],\"value\":\"$version\"}]"

    write_info 'Update complete.'
}

# Helper: scan foreign files for given tools
invoke_scan_foreign_for_tools() {
    local root="$1"
    local active_tools="$2"
    local source_root="$3"

    local mf="$root/$MANIFEST_FILE_NAME"
    local managed_files
    managed_files="$(python3 -c "import json; m=json.load(open('$mf')) if __import__('os').path.isfile('$mf') else {}; print(json.dumps(list(m.get('files',{}).keys())))" 2>/dev/null || echo '[]')"

    local adapters_json='{}'
    for t in $active_tools; do
        local p="$source_root/adapters/$t.yaml"
        local adapter_obj='{}'
        if [[ -f "$p" ]]; then
            adapter_obj="$(py_parse_adapter "$p" 2>/dev/null || echo '{}')"
        fi
        adapters_json="$(python3 - "$adapters_json" "$t" "$adapter_obj" <<'PY'
import json,sys
acc=json.loads(sys.argv[1])
tool=sys.argv[2]
obj=json.loads(sys.argv[3])
acc[tool]=obj
print(json.dumps(acc))
PY
)"
    done

    local tools_arr
    tools_arr="$(echo "$active_tools" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().split()))")"
    printf '%s' "{\"root\":\"$root\",\"activeTools\":$tools_arr,\"managedFiles\":$managed_files,\"adapters\":$adapters_json}" | py_scan_foreign
}

# ---- add --------------------------------------------------------------------

cmd_add() {
    local root="$1"
    local source_root_req="$2"
    local new_tool="$3"

    [[ -z "$new_tool" ]] && write_err "--tool is required for add command" && exit 1

    local valid=0
    for st in $SUPPORTED_TOOLS; do [[ "$new_tool" == "$st" ]] && valid=1 && break; done
    [[ $valid -eq 0 ]] && write_err "Unknown tool: $new_tool" && exit 1

    if ! manifest_exists "$root"; then
        write_err "No manifest found. Run init first."
        exit 1
    fi

    local manifest_json
    manifest_json="$(manifest_read "$root")"
    local already_installed
    already_installed="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); print('1' if '$new_tool' in m.get('tools',[]) else '0')")"
    if [[ "$already_installed" == '1' ]]; then
        write_warn "$new_tool already installed. Use 'update' to refresh."
        return
    fi

    local source_root
    source_root="$(resolve_source_root "$source_root_req")"
    local foreign_json
    foreign_json="$(invoke_scan_foreign_for_tools "$root" "$new_tool" "$source_root")"

    write_section "Placing files for tool: $new_tool"
    invoke_place_phase "$root" "$source_root" "$new_tool"
    invoke_openspec_artifacts "$root" "$source_root" "$new_tool"
    invoke_mcp_phase "$root" "$source_root" "$new_tool"

    # Merge foreign
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"foreignFiles\",\"$new_tool\"],\"value\":$(printf '%s' "$foreign_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('$new_tool',[])))") }]"

    # Append to tools list
    manifest_patch "$root" "[{\"op\":\"append\",\"path\":[\"tools\"],\"value\":\"$new_tool\"}]"

    # Update AGENTS.md with full active tool set
    local all_tools
    all_tools="$(python3 -c "import json; m=json.load(open('$root/$MANIFEST_FILE_NAME')); print(' '.join(m.get('tools',[])))")"
    update_agents_md "$root" "$source_root" "$all_tools"
    place_root_templates "$root" "$source_root"

    local ts
    ts="$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")"
    manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"updatedAt\"],\"value\":\"$ts\"}]"

    write_info "Added rules for $new_tool."
}

# ---- remove -----------------------------------------------------------------

cmd_remove() {
    local root="$1"
    local scope_tool="$2"

    if ! manifest_exists "$root"; then
        write_info "No manifest; nothing to remove."
        return
    fi

    local manifest_json
    manifest_json="$(manifest_read "$root")"

    if [[ -n "$scope_tool" ]]; then
        local is_installed
        is_installed="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); print('1' if '$scope_tool' in m.get('tools',[]) else '0')")"
        if [[ "$is_installed" == '0' ]]; then
            write_warn "$scope_tool is not installed."
            return
        fi

        write_info "Removing rules for $scope_tool only."
        local tool_prefixes
        case "$scope_tool" in
            claude-code)   tool_prefixes='.claude/ CLAUDE.md .mcp.json' ;;
            command-code)  tool_prefixes='.commandcode/ .mcp.json' ;;
            codex)         tool_prefixes='.codex/' ;;
            opencode)      tool_prefixes='.opencode/ opencode.json' ;;
            kilocode)      tool_prefixes='.kilo/ .kilocode/' ;;
            kimi)          tool_prefixes='.kimi-code/ .kimi/' ;;
            qwen)          tool_prefixes='.qwen/ QWEN.md' ;;
            cline)         tool_prefixes='.cline/ .clinerules/' ;;
            pi)            tool_prefixes='.pi/' ;;
            cursor)        tool_prefixes='.cursor/' ;;
            other)         tool_prefixes='.ai-agent/' ;;
            *)             tool_prefixes=".$scope_tool/" ;;
        esac

        local to_remove
        to_remove="$(python3 - "$manifest_json" "$tool_prefixes" <<'PY'
import json,sys
m=json.loads(sys.argv[1])
prefixes=sys.argv[2].split()
to_remove=[]
for rel in m.get('files',{}):
    for p in prefixes:
        if rel==p.rstrip('/') or rel.startswith(p.rstrip('/')+'/') or rel==p:
            to_remove.append(rel)
            break
print('\n'.join(to_remove))
PY
)"

        local del_ops='['
        local first=1
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            local abs="$root/$rel"
            [[ -f "$abs" ]] && rm -f "$abs"
            [[ $first -eq 0 ]] && del_ops+=','
            del_ops+="{\"op\":\"del_file_entry\",\"rel\":\"$rel\"}"
            first=0
        done <<< "$to_remove"
        del_ops+=']'
        [[ "$del_ops" != '[]' ]] && manifest_patch "$root" "$del_ops"

        # Clean up empty skeleton dirs owned by this tool
        local cleanup_dirs=""
        case "$scope_tool" in
            other)         cleanup_dirs='.ai-agent' ;;
            kilocode)      cleanup_dirs='.kilo .kilocode' ;;
            kimi)          cleanup_dirs='.kimi-code .kimi' ;;
            command-code)  cleanup_dirs='.commandcode' ;;
            claude-code)   cleanup_dirs='.claude' ;;
            qwen)          cleanup_dirs='.qwen' ;;
            cline)         cleanup_dirs='.cline .clinerules' ;;
            pi)            cleanup_dirs='.pi' ;;
            codex)         cleanup_dirs='.codex' ;;
            opencode)      cleanup_dirs='.opencode' ;;
            cursor)        cleanup_dirs='.cursor' ;;
            *)             cleanup_dirs=".$scope_tool" ;;
        esac
        for d in $cleanup_dirs; do
            local dir_path="$root/$d"
            if [[ -d "$dir_path" ]]; then
                local remaining_files
                remaining_files="$(find "$dir_path" -type f 2>/dev/null | head -1)"
                [[ -z "$remaining_files" ]] && rm -rf "$dir_path"
            fi
        done

        # Remove tool from tools list and foreignFiles
        manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"tools\"],\"value\":$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); print(json.dumps([t for t in m.get('tools',[]) if t!='$scope_tool']))")},{\"op\":\"del_key\",\"path\":[\"foreignFiles\",\"$scope_tool\"]}]"

        local remaining_tools
        remaining_tools="$(python3 -c "import json; m=json.load(open('$root/$MANIFEST_FILE_NAME')); print(len(m.get('tools',[])))")"
        if [[ "$remaining_tools" == '0' ]]; then
            local agents_path="$root/$AGENTS_MD_FILE_NAME"
            [[ -f "$agents_path" ]] && rm -f "$agents_path"
            manifest_patch "$root" "[{\"op\":\"del_file_entry\",\"rel\":\"$AGENTS_MD_FILE_NAME\"}]"
            rm -f "$root/$MANIFEST_FILE_NAME"
            write_info "All tools removed; manifest deleted."
            return
        fi

        local remove_count
        remove_count="$(printf '%s' "$to_remove" | grep -c . || echo 0)"
        local ts
        ts="$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")"
        manifest_patch "$root" "[{\"op\":\"set\",\"path\":[\"updatedAt\"],\"value\":\"$ts\"}]"
        write_info "Removed $scope_tool ($remove_count files)."
    else
        write_info "Removing all installed files."
        python3 - "$manifest_json" "$root" <<'PY'
import json,sys,os
m=json.loads(sys.argv[1])
root=sys.argv[2]
for rel in m.get('files',{}):
    abs_path=os.path.expanduser(rel) if rel.startswith('~') else os.path.join(root,rel)
    if os.path.isfile(abs_path):
        os.remove(abs_path)
PY
        rm -f "$root/$MANIFEST_FILE_NAME"

        # Clean up empty dirs
        local cleanup_dirs=".ai-rules"
        while IFS= read -r t; do
            case "$t" in
                other) cleanup_dirs="$cleanup_dirs .ai-agent" ;;
                kilocode) cleanup_dirs="$cleanup_dirs .kilo .kilocode" ;;
                kimi) cleanup_dirs="$cleanup_dirs .kimi-code .kimi" ;;
                command-code) cleanup_dirs="$cleanup_dirs .commandcode" ;;
                claude-code) cleanup_dirs="$cleanup_dirs .claude" ;;
                qwen) cleanup_dirs="$cleanup_dirs .qwen" ;;
                cline) cleanup_dirs="$cleanup_dirs .cline .clinerules" ;;
                pi) cleanup_dirs="$cleanup_dirs .pi" ;;
                codex) cleanup_dirs="$cleanup_dirs .codex" ;;
                opencode) cleanup_dirs="$cleanup_dirs .opencode" ;;
                cursor) cleanup_dirs="$cleanup_dirs .cursor" ;;
                *) cleanup_dirs="$cleanup_dirs .$t" ;;
            esac
        done < <(printf '%s' "$manifest_json" | python3 -c "import json,sys; [print(t) for t in json.load(sys.stdin).get('tools',[])]")

        for d in $cleanup_dirs; do
            local dir_path="$root/$d"
            if [[ -d "$dir_path" ]]; then
                local remaining_files
                remaining_files="$(find "$dir_path" -type f 2>/dev/null | head -1)"
                [[ -z "$remaining_files" ]] && rm -rf "$dir_path"
            fi
        done
        write_info 'Removal complete.'
    fi
}

# ---- doctor -----------------------------------------------------------------

cmd_doctor() {
    local root="$1"

    if ! manifest_exists "$root"; then
        write_info "No manifest found. Nothing installed."
        return
    fi

    local manifest_json
    manifest_json="$(manifest_read "$root")"

    write_section 'Installed'
    python3 - "$manifest_json" <<'PY'
import json,sys
m=json.loads(sys.argv[1])
print('Protocol: '+str(m.get('protocol','')))
print('Version: '+str(m.get('version',''))+' (installed '+str(m.get('installedAt',''))+', updated '+str(m.get('updatedAt',''))+')')
print('Tools: '+', '.join(m.get('tools',[])))
print('Files: '+str(len(m.get('files',{}))))
print('MCP servers: '+', '.join(m.get('mcpServers',[])))
PY

    write_section 'File integrity'
    local verify
    verify="$(invoke_verify "$root")"
    python3 - "$verify" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
if v['ok']:
    print(f"All {v['count']} files match manifest.")
else:
    print(f"Mismatches: {len(v['mismatches'])}")
    for m in v['mismatches']:
        print(f"  {m}")
PY

    write_section 'User-modified files'
    local user_mod
    user_mod="$(printf '%s' "$manifest_json" | python3 -c "import json,sys; m=json.load(sys.stdin); r=[k for k,v in m.get('files',{}).items() if v.get('userModified')]; print('\n'.join(r) if r else 'None.')")"
    echo "$user_mod"

    write_section 'Foreign files'
    python3 - "$manifest_json" <<'PY'
import json,sys
m=json.loads(sys.argv[1])
ff=m.get('foreignFiles',{})
for t,files in ff.items():
    if files:
        print(f"  {t}: {len(files)} file(s)")
PY

    write_section 'Integrations'
    python3 - "$manifest_json" <<'PY'
import json,sys
m=json.loads(sys.argv[1])
integ=m.get('integrations',{})
if not integ:
    print('  (none)')
    sys.exit()
found=False
for k,i in integ.items():
    if i.get('detected'):
        tag=' [scaffolded]' if i.get('scaffolded') else ''
        bundle=f" [artefacts v{i['artifactsBundleVersion']}]" if i.get('artifactsBundleVersion') else ''
        print(f"  {k}: detected ({len(i.get('files',[]))} files){tag}{bundle}")
        found=True
if not found:
    print('  (none)')
PY
}

# ---- eject ------------------------------------------------------------------

cmd_eject() {
    local root="$1"
    local mf_path="$root/$MANIFEST_FILE_NAME"
    if [[ ! -f "$mf_path" ]]; then
        write_info "No manifest to eject."
        return
    fi
    rm -f "$mf_path"
    write_info "Manifest removed. Installed files are preserved; future installers will treat them as foreign."
}

# ============================================================================
# SECTION 17: MAIN DISPATCH
# ============================================================================

# Resolve project root
if [[ -n "$ARG_PROJECT_ROOT" ]]; then
    if [[ ! -d "$ARG_PROJECT_ROOT" ]]; then
        write_err "ProjectRoot does not exist: $ARG_PROJECT_ROOT"
        exit 1
    fi
    PROJECT_ROOT="$(cd "$ARG_PROJECT_ROOT" && pwd)"
else
    PROJECT_ROOT="$(pwd)"
fi

# Normalise --tools: accept comma-separated
TOOLS_NORMALIZED=''
if [[ -n "$ARG_TOOLS" ]]; then
    TOOLS_NORMALIZED="$(echo "$ARG_TOOLS" | tr ',' ' ' | tr -s ' ')"
fi

# Check Python3 is available
if ! command -v python3 &>/dev/null; then
    write_err "python3 is required but not found in PATH."
    write_err "Install it via: brew install python3"
    exit 1
fi

set +e  # Allow non-zero exit from commands to be handled gracefully
(
    set -e
    case "$COMMAND" in
        init)   cmd_init   "$PROJECT_ROOT" "$ARG_SOURCE" "$TOOLS_NORMALIZED" ;;
        update) cmd_update "$PROJECT_ROOT" "$ARG_SOURCE" ;;
        add)    cmd_add    "$PROJECT_ROOT" "$ARG_SOURCE" "$ARG_TOOL" ;;
        remove) cmd_remove "$PROJECT_ROOT" "$ARG_TOOL" ;;
        doctor) cmd_doctor "$PROJECT_ROOT" ;;
        eject)  cmd_eject  "$PROJECT_ROOT" ;;
    esac
)
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    write_err "Command failed with exit code $EXIT_CODE"
    exit $EXIT_CODE
fi

# If this script is in the same repo as refresh-openspec-bundle.sh, show note
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/tools/refresh-openspec-bundle.sh" && "$COMMAND" =~ ^(init|update)$ ]]; then
    echo ""
    echo "Note: To refresh the bundled OpenSpec snapshots (content/openspec-bundle/), run:"
    echo "  ./tools/refresh-openspec-bundle.sh [--dry-run]"
    echo "This requires Node.js + npm and the OpenSpec CLI installed globally."
fi
