## nimteractive — persistent warm Nim session server.
## Reads line-delimited JSON requests from stdin, writes responses to stdout.

import std/[os, times]
import nimteractive/[protocol, compiler, hotreload, session]

var currentKey = ""

proc handlePrecompile(req: Request) =
  send Response(id: req.id, kind: rkCompiling)
  let key = cacheKey(req.imports)
  let t0 = epochTime()
  var hit = true
  if not fileExists(hostBinary(key)):
    hit = false
    let ok = compileHost(req.imports, key)
    if not ok:
      send Response(id: req.id, kind: rkError,
                    msg: "core compilation failed — check stderr")
      return
  currentKey = key
  initSession(extraPaths = @[sessionCacheDir(key)])
  let elapsed = int((epochTime() - t0) * 1000)
  send Response(id: req.id, kind: rkReady, cacheHit: hit, elapsedMs: elapsed)

proc handleLoadProcs(req: Request) =
  if currentKey == "":
    send Response(id: req.id, kind: rkError,
                  msg: "no core compiled yet — run :precompile first")
    return
  send Response(id: req.id, kind: rkCompiling)
  let t0 = epochTime()
  let (ok, msg) = compileProcs(req.procsCode, currentKey)
  if not ok:
    send Response(id: req.id, kind: rkError, msg: msg)
    return
  let (lok, lmsg) = loadProcs(procsSo(currentKey))
  if not lok:
    send Response(id: req.id, kind: rkError, msg: lmsg)
    return
  let elapsed = int((epochTime() - t0) * 1000)
  send Response(id: req.id, kind: rkReloaded, elapsedMs: elapsed)

proc handleEval(req: Request) =
  let (value, stdout, err) = evalBlock(req.evalCode)
  if err != "":
    send Response(id: req.id, kind: rkError, msg: err)
  else:
    send Response(id: req.id, kind: rkResult, stdout: stdout, value: value)

proc handleComplete(req: Request) =
  # Placeholder — completions will query the VM's symbol table
  send Response(id: req.id, kind: rkCompletions, items: @[])

proc main() =
  for line in stdin.lines:
    let line = line.strip()
    if line == "": continue
    try:
      let req = parseRequest(line)
      case req.op
      of opPrecompile: handlePrecompile(req)
      of opLoadProcs:  handleLoadProcs(req)
      of opEval:       handleEval(req)
      of opComplete:   handleComplete(req)
    except:
      send Response(id: "?", kind: rkError, msg: getCurrentExceptionMsg())

main()
