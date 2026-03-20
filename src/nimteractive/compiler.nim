## Cache key computation and stdlib path discovery.
## The precompile step warms up the module graph inside the running process;
## no separate host binary is needed.

import std/[os, osproc, sha1, algorithm, strutils]

const CacheBase = "~/.cache/nimteractive"

proc cacheDir*(): string =
  expandTilde(CacheBase)

proc nimVersion*(): string =
  let (output, _) = execCmdEx("nim --version")
  result = output.splitLines()[0]

proc lockfileHash*(): string =
  let lf = getCurrentDir() / "nimble.lock"
  if fileExists(lf): $secureHash(readFile(lf))
  else: ""

proc cacheKey*(imports: seq[string]): string =
  let raw = imports.sorted.join("|") & "|" & nimVersion() & "|" & lockfileHash()
  result = ($secureHash(raw))[0..15]

proc sessionCacheDir*(key: string): string =
  cacheDir() / key

proc procsSo*(key: string): string =
  sessionCacheDir(key) / "procs.so"

proc procsSource*(key: string): string =
  sessionCacheDir(key) / "procs.nim"

proc nimStdlibPathRuntime*(): string =
  ## Discover stdlib path at runtime via `nim dump`.
  let (output, code) = execCmdEx("nim dump --dump.format:json . 2>/dev/null")
  if code == 0:
    # parse "libpath" from JSON output
    for line in output.splitLines:
      let l = line.strip()
      if "\"libpath\"" in l:
        let start = l.find(':') + 1
        result = l[start..^1].strip().strip(chars = {'"', ','})
        if result.len > 0: return
  # fallback: derive from nim executable location
  let (nimExe, _) = execCmdEx("which nim")
  result = nimExe.strip().parentDir.parentDir / "lib"
