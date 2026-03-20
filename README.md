# nimteractive

A persistent warm Nim session for interactive use from Emacs org-babel and Jupyter.

## The Problem

Nim is fast — but cold-starting a script that imports `datamancer` or `arraymancer` means paying generic instantiation and macro expansion costs on every single run. Interactive data exploration becomes painful when each tweak takes seconds to compile.

nimteractive solves this with a three-layer architecture that compiles your imports once and keeps the session alive.

## Architecture

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

- **Core** — built once, cached by `sha256(imports | nim_version | nimble.lock)`. Survives Emacs restarts.
- **Procs** — recompiled to a `.so` and hot-swapped via `dlopen` each time you re-execute the `:procs t` block. No session restart needed.
- **Eval** — instant. Expressions are sent to the running VM; no imports, no generics, just execution.

## Installation

### 1. Build the binary

```sh
cd nimteractive
nim c -o:nimteractive src/nimteractive.nim
# or via nimble:
nimble build
```

Put the resulting `nimteractive` binary somewhere on your `PATH` (e.g. `~/.nimble/bin/`).

### 2. Install the Emacs package

With `use-package` and the built-in `:vc` fetcher (Emacs 30+):

```emacs-lisp
(use-package ob-nimteractive
  :vc (:url "~/nimteractive" :lisp-dir ".")
  :config
  (ob-nimteractive-setup))
```

Or load the file directly:

```emacs-lisp
(load "~/nimteractive/ob-nimteractive.el")
(ob-nimteractive-setup)
```

`ob-nimteractive-setup` registers `nim` with org-babel and pins `*Nimteractive:*` buffers to a bottom side window (like ESS does for `*R*`).

## Emacs Usage

### org-babel blocks

Three block types, selected by header arguments:

**1. Precompile** — run once per session. Compiles your imports and caches the result.

```org
#+begin_src nim :session analysis :precompile t
import datamancer
import fastsem
#+end_src
```

Output: `[session ready — 4200ms]` on first run, `[session ready — 80ms, cached]` thereafter.

**2. Procs** — define reusable procedures. Re-execute to hot-reload without restarting.

```org
#+begin_src nim :session analysis :procs t
proc normalize(df: DataFrame, col: string): DataFrame =
  let mu = df[col].mean
  let sd = df[col].std
  result = df.mutate(col, (c: float) => (c - mu) / sd)
#+end_src
```

**3. Eval** — interactive code. State accumulates across blocks.

```org
#+begin_src nim :session analysis
let df = readCsv("data.csv")
let clean = df.normalize("score")
echo clean.head(5)
#+end_src
```

### Interactive session buffer

Each session gets a `*Nimteractive:<name>*` comint buffer — a live REPL backed by the same process that org-babel uses.

| Key | Action |
|-----|--------|
| `C-c C-v z` | Jump to (or open) the session buffer |
| `RET` | Send current input as an eval request |

With a prefix argument (`C-u C-c C-v z`) you are prompted for a session name — useful when working with multiple named sessions.

When you open a nim source block with `C-c '` (org-edit-src), the session buffer is automatically displayed alongside the edit buffer, mirroring the ESS workflow.

### Session management

```emacs-lisp
;; Show session buffer (interactive)
M-x ob-nimteractive-show-session

;; Clean shutdown (sends exit op)
M-x ob-nimteractive-exit-session

;; Hard kill
M-x ob-nimteractive-kill-session
```

### Configuration

```emacs-lisp
;; Path to binary (auto-detected from PATH / ~/.nimble/bin/)
(setq ob-nimteractive-binary "/path/to/nimteractive")

;; Prompt string (must match what the server emits)
(setq ob-nimteractive-prompt "nim> ")

;; Seconds to wait for a response before timing out
(setq ob-nimteractive-timeout 120)
```

## Protocol

The server communicates over stdin/stdout using line-delimited JSON. You can drive it from any editor or script.

```
→ {"op": "eval",       "id": "1", "code": "echo 1+1"}
← {"op": "result",     "id": "1", "stdout": "2\n", "value": ""}

→ {"op": "precompile", "id": "2", "imports": ["datamancer"]}
← {"op": "compiling",  "id": "2"}
← {"op": "ready",      "id": "2", "cache_hit": false, "elapsed_ms": 4200}

→ {"op": "load_procs", "id": "3", "code": "proc double(n: int): int = n * 2"}
← {"op": "compiling",  "id": "3"}
← {"op": "reloaded",   "id": "3", "elapsed_ms": 1100}

→ {"op": "complete",   "id": "4", "code": "df[\"", "cursor": 4}
← {"op": "completions","id": "4", "items": []}

→ {"op": "exit",       "id": "5"}
← {"op": "result",     "id": "5", "stdout": "bye", "value": ""}
```

## Cache

Cache key: `sha256(sorted_imports | nim_version | nimble.lock)`

Stored under `~/.cache/nimteractive/<hash>/`:

| File | Contents |
|------|----------|
| `host` | compiled core binary |
| `host.nim` | generated source (for debugging) |
| `procs.so` | last compiled procs shared library |

The cache invalidates automatically when you upgrade Nim or change package versions.

## Requirements

- Nim ≥ 2.2.0
- Emacs ≥ 29.1, Org ≥ 9.6 (for the Emacs integration)

## License

MIT
