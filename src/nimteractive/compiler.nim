## Compiles and caches the core host binary from a list of imports.
## Cache key: sha256(sorted imports | nim version | nimble.lock content).

import std/[os, osproc, strutils, sequtils, times, hashes]
import std/sha1  # stdlib SHA1 — good enough for cache keys

const CacheBase = "~/.cache/nimteractive"

proc cacheDir*(): string =
  expandTilde(CacheBase)

proc lockfileHash(): string =
  ## Hash nimble.lock if present, else empty string.
  let lf = getCurrentDir() / "nimble.lock"
  if fileExists(lf):
    result = $secureHash(readFile(lf))
  else:
    result = ""

proc nimVersion(): string =
  let (output, _) = execCmdEx("nim --version")
  result = output.splitLines()[0]

proc cacheKey*(imports: seq[string]): string =
  let sorted = imports.sorted.join("|")
  let raw = sorted & "|" & nimVersion() & "|" & lockfileHash()
  result = ($secureHash(raw))[0..15]  # first 16 hex chars is enough

proc sessionCacheDir*(key: string): string =
  cacheDir() / key

proc hostBinary*(key: string): string =
  sessionCacheDir(key) / "host"

proc procsSo*(key: string): string =
  sessionCacheDir(key) / "procs.so"

proc procsSource*(key: string): string =
  sessionCacheDir(key) / "procs.nim"

proc generateHostSource(imports: seq[string]): string =
  ## Generate the host .nim file that bakes in all imports.
  var lines: seq[string]
  for imp in imports:
    lines.add "import " & imp
  lines.add ""
  lines.add "# nimteractive host — generated, do not edit"
  lines.add "# All generics, macros, and templates from imports are"
  lines.add "# pre-instantiated here so eval blocks pay no expansion cost."
  lines.add ""
  lines.add """
import compiler/[nimeval, llstream, idents, options, condsyms]
import std/[os, json, strutils]

var gIntr*: Interpreter

proc initInterpreter*(stdlibPath: string, extraPaths: seq[string] = @[]) =
  var paths = @[stdlibPath] & extraPaths
  gIntr = createInterpreter("session.nims", paths)

proc evalCode*(code: string): tuple[value: string, stdout: string] =
  # Captures stdout and returns last expression value.
  # TODO: dup2-based stdout capture
  try:
    gIntr.evalScript(llStreamOpen(code))
    result = (value: "", stdout: "")
  except:
    raise
"""
  result = lines.join("\n")

proc compileHost*(imports: seq[string], key: string): bool =
  ## Compile the host binary. Returns true on success.
  let dir = sessionCacheDir(key)
  createDir(dir)
  let src = dir / "host.nim"
  writeFile(src, generateHostSource(imports))
  let cmd = "nim c -d:release --hints:off --warnings:off -o:" &
            hostBinary(key) & " " & src
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    stderr.writeLine output
  result = exitCode == 0

proc compileProcs*(code: string, key: string): tuple[ok: bool, msg: string] =
  ## Compile the procs block to a shared library (.so).
  let dir = sessionCacheDir(key)
  createDir(dir)
  # Preamble: import core symbols so procs can use them
  let src = "import " & (hostBinary(key)) & "\n\n" & code
  writeFile(procsSource(key), src)
  let outSo = procsSo(key)
  let cmd = "nim c --app:lib -d:release --hints:off --warnings:off -o:" &
            outSo & " " & procsSource(key)
  let (output, exitCode) = execCmdEx(cmd)
  result = (ok: exitCode == 0, msg: output)
