## Hot-reload the procs shared library via dlopen/dlsym.
## The core binary is never restarted; only the procs .so is swapped.

import std/[dynlib, os, tables]

type
  ProcHandle* = object
    lib*: LibHandle
    syms*: Table[string, pointer]

var gProcs*: ProcHandle

proc loadProcs*(soPath: string): tuple[ok: bool, msg: string] =
  ## dlclose old .so (if loaded), dlopen new one, rebuild symbol table.
  if gProcs.lib != nil:
    unloadLib(gProcs.lib)
    gProcs.lib = nil
    gProcs.syms.clear()

  if not fileExists(soPath):
    return (false, "procs .so not found: " & soPath)

  let lib = loadLib(soPath)
  if lib == nil:
    return (false, "dlopen failed for: " & soPath)

  gProcs.lib = lib
  # Symbol discovery: the .so exports a NimMain and whatever the user defined.
  # Specific procs are looked up on-demand via symAddr below.
  return (true, "")

proc symAddr*(name: string): pointer =
  ## Look up a symbol from the loaded procs .so.
  if gProcs.lib == nil: return nil
  if name in gProcs.syms: return gProcs.syms[name]
  let p = gProcs.lib.symAddr(name)
  if p != nil:
    gProcs.syms[name] = p
  result = p

proc procsLoaded*(): bool =
  gProcs.lib != nil
