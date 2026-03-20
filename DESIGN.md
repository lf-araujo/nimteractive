# nimteractive

Persistent warm Nim session for interactive use from Emacs org-babel and Jupyter.

## The Problem

NimScript VM re-parses and re-evaluates source on every invocation. Even with a
persistent process, heavy libraries (datamancer, arraymancer) pay generic
instantiation and macro expansion costs at eval time, making interactive use
sluggish.

## Architecture

Three layers, each with a distinct lifecycle:

```
┌─────────────────────────────────────────────────────────────┐
│  CORE  (stable, compiled binary)                            │
│  imports datamancer, fastsem, arraymancer, ...              │
│  compiled once, cached by hash(imports + nim version)       │
│  recompiled only when the :precompile chunk changes         │
└────────────────────────┬────────────────────────────────────┘
                         │ dlopen
┌────────────────────────▼────────────────────────────────────┐
│  PROCS  (hot-reloaded shared library)                       │
│  user-defined procs that call into core                     │
│  compiled to .so on save, swapped live via dlopen/dlsym     │
│  VM function pointers updated; no restart needed            │
└────────────────────────┬────────────────────────────────────┘
                         │ call
┌────────────────────────▼────────────────────────────────────┐
│  EVAL  (interactive blocks)                                 │
│  arbitrary expressions sent block by block                  │
│  calls into core symbols and hot-reloaded procs             │
│  AST-walk cost only (no imports, no generic instantiation)  │
└─────────────────────────────────────────────────────────────┘
```

## Org-babel Usage

```org
# 1. Core chunk — run once, triggers compilation if cache miss
#+begin_src nim :session analysis :precompile t
import datamancer
import fastsem
#+end_src

# 2. Procs chunk — hot-reloaded on every execution
#+begin_src nim :session analysis :procs t
proc normalize(df: DataFrame, col: string): DataFrame =
  let mu = df[col].mean
  let sd = df[col].std
  result = df.mutate(col, (c: float) => (c - mu) / sd)
#+end_src

# 3. Regular eval blocks — fast, call into core + procs
#+begin_src nim :session analysis
let df = readCsv("data.csv")
let clean = df.normalize("score")
echo clean.head(5)
#+end_src
```

## Protocol

Line-delimited JSON over stdin/stdout. Synchronous request/response per message.

```
→ {"op": "eval",       "code": "...", "id": "1"}
← {"op": "result",     "id": "1", "stdout": "...", "value": "..."}
← {"op": "error",      "id": "1", "msg": "..."}

→ {"op": "precompile", "imports": ["datamancer", "fastsem"], "id": "2"}
← {"op": "compiling",  "id": "2"}
← {"op": "ready",      "id": "2", "cache_hit": true, "elapsed_ms": 80}

→ {"op": "load_procs", "code": "...", "id": "3"}
← {"op": "compiling",  "id": "3"}
← {"op": "reloaded",   "id": "3", "elapsed_ms": 1200}

→ {"op": "complete",   "code": "df[\"", "cursor": 4, "id": "4"}
← {"op": "completions","id": "4", "items": ["col1", "col2"]}
```

## File Layout

```
nimteractive/
├── nimteractive.nimble
├── DESIGN.md
├── src/
│   ├── nimteractive.nim        # entry point / server loop
│   └── nimteractive/
│       ├── protocol.nim        # JSON message types, read/write
│       ├── compiler.nim        # compile core binary, cache by hash
│       ├── hotreload.nim       # compile procs to .so, dlopen/dlsym
│       └── session.nim         # VM state, eval, symbol tracking
├── editors/
│   └── emacs/
│       └── ob-nimteractive.el  # org-babel backend + comint buffer
└── tests/
```

## Cache Strategy

Cache key: `sha256(sorted_imports | nim_version | nimble.lock)`

Stored in `~/.cache/nimteractive/<hash>/`:
- `host` — compiled binary
- `host.nim` — generated source (for debugging)
- `procs.so` — last compiled procs shared library

Cache invalidates automatically on Nim upgrade or package version change.

## Hot Reload Mechanism

1. User re-executes the `:procs t` block
2. ob-nimteractive sends `load_procs` with the block source
3. Server writes source to `~/.cache/nimteractive/<hash>/procs.nim`
4. Compiles with `--app:lib -d:release`
5. `dlclose` old `.so`, `dlopen` new `.so`
6. Updates function pointer table in the VM scope
7. Responds `reloaded`

The core binary is never restarted. DataFrame state, fitted models, loaded data — all survive a procs reload.

## Emacs Integration

- `*Nimteractive*` comint buffer — interactive terminal, shared process with ob
- `C-c C-z` — jump to session buffer (like ESS)
- `C-c C-c` or `C-RET` — send expression from comint buffer
- `:session <name>` header — named sessions, multiple sessions supported
- `ob-nimteractive-start-session` — starts session, shows "compiling..." if cache miss

## Out of Scope (for now)

- Checkpoint/restore of VM state
- VS Code extension
- TCP socket transport (stdin/stdout pipe only)
