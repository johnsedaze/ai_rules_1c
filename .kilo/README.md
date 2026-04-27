# Kilo Code Custom Subagents Configuration

This repository demonstrates proper configuration of custom subagents for the Kilo Code VSCode extension, following the [official documentation](https://kilo.ai/docs/customize/custom-subagents).

## Overview

Custom subagents are specialized AI assistants that run in isolated contexts with tailored prompts, models, and tool access. They can be invoked by primary agents or manually via `@` mentions.

## Configuration Methods

### Method 1: Markdown Files (Recommended)

**Location**: `.kilo/agents/*.md`

Each markdown file defines one subagent. The filename (without `.md`) becomes the agent name.

**Example**: `.kilo/agents/1c-analytic.md`

```markdown
---
description: Expert 1C business analyst agent...
mode: subagent
model: anthropic/claude-3-opus-20240229
temperature: 0.3
steps: 25
permission:
  edit: deny
  bash: deny
  task:
    "*": deny
    "general": allow
---

# 1C Business Analyst Agent

You are an experienced 1C business analyst...
```

### Method 2: JSON Configuration

**Location**: `kilo.jsonc` (project) or `~/.config/kilo/config.json` (global)

```jsonc
{
  "agent": {
    "1c-analytic": {
      "description": "Expert 1C business analyst...",
      "mode": "subagent",
      "model": "anthropic/claude-3-opus-20240229",
      "temperature": 0.3,
      "permission": {
        "edit": "deny",
        "bash": "deny"
      }
    }
  }
}
```

## Available Subagents

### 1c-analytic
- **Purpose**: Business analysis, PRD creation, technical documentation
- **Model**: Claude 3 Opus
- **Permissions**: Read-only, can delegate to other agents
- **Usage**: `@1c-analytic analyze the order processing system`

### 1c-code-reviewer
- **Purpose**: Code review for best practices and security
- **Model**: Claude 3 Opus
- **Permissions**: Read-only
- **Usage**: `@1c-code-reviewer review Document.Realization.ManagerModule`

### 1c-architect
- **Purpose**: Metadata architecture design
- **Model**: Claude 3 Opus
- **Permissions**: Read-only, can access metadata tools
- **Usage**: `@1c-architect design integration with external WMS`

## Configuration Options

| Option | Type | Description |
|--------|------|-------------|
| `description` | string | What the agent does (used by primary agents) |
| `mode` | enum | `subagent`, `primary`, or `all` |
| `model` | string | Provider/model ID (e.g., `anthropic/claude-3-opus-20240229`) |
| `temperature` | number | 0.0-1.0 (lower = more deterministic) |
| `steps` | number | Max agentic iterations |
| `color` | string | UI color (hex or theme name) |
| `permission` | object | Tool access control |
| `hidden` | boolean | Hide from `@` menu |
| `disable` | boolean | Disable the agent |

## Permission Configuration

Each tool can be set to:
- `"allow"` - Allow without approval
- `"ask"` - Prompt for approval
- `"deny"` - Disable entirely

### Bash Command Patterns

```json
"permission": {
  "bash": {
    "*": "ask",           // Default for all commands
    "git diff": "allow",   // Specific command
    "git log*": "allow"    // Glob pattern
  }
}
```

### Task Delegation

Control which subagents an agent can invoke:

```json
"permission": {
  "task": {
    "*": "deny",           // Deny all by default
    "code-reviewer": "allow",
    "docs-writer": "allow"
  }
}
```

## Using Subagents

### Manual Invocation

Type `@agent-name` in your message:

```
@1c-analytic Create a PRD for the inventory tracking module
```

### Automatic Invocation

Primary agents automatically invoke subagents when their description matches the task.

### Listing Agents

```bash
kilo agent list
```

## Configuration Precedence

1. Built-in agent defaults
2. Global config (`~/.config/kilo/config.json`)
3. Project config (`kilo.jsonc`)
4. Global agent markdown (`~/.config/kilo/agents/*.md`)
5. Project agent markdown (`.kilo/agents/*.md`)

Later sources override earlier ones.

## Best Practices

1. **Use markdown for complex prompts** - Easier to read and maintain
2. **Set appropriate permissions** - Restrict edit/bash for analysis agents
3. **Define clear descriptions** - Helps primary agents select the right subagent
4. **Use lower temperature** - For deterministic tasks like code review
5. **Limit steps** - Control costs and prevent infinite loops

## Troubleshooting

### Agent not appearing

- Check file location: `.kilo/agents/*.md` (project) or `~/.config/kilo/agents/*.md` (global)
- Verify YAML frontmatter syntax
- Run `kilo agent list` to see all available agents

### Permissions not working

- Check for conflicting rules (last matching rule wins)
- Verify tool names match exactly
- Use `"*"` to set default permission

### Model not respected

- Verify model format: `provider/model-id`
- Check if model is available in your Kilo Gateway configuration

## Examples

See `.kilo/agents/*.md` for complete working examples.

## Related Documentation

- [Custom Subagents Guide](https://kilo.ai/docs/customize/custom-subagents)
- [agents.md Reference](https://kilo.ai/docs/customize/agents-md)
- [Custom Modes](https://kilo.ai/docs/customize/custom-modes)
