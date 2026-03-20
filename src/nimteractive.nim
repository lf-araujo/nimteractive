## nimteractive — persistent warm Nim session server.
## Reads line-delimited JSON requests from stdin, writes responses to stdout.
##
## Session buffer structure:
##   imports  <- set by "precompile" op, warms module graph
##   procs    <- set by "load_procs" op, replaced on each reload
##   history  <- "eval" ops appended sequentially
##
## State persists across evals. Changing procs clears history (expected).
## Changing imports resets everything (module graph rebuilt).

import std/[times, strutils, sequtils]
import nimteractive/[protocol, session]

proc handlePrecompile(req: Request) =
  send Response(id: req.id, kind: rkCompiling)
  let t0 = epochTime()
  let code = req.imports.mapIt("import " & it).join("\n")
  let (_, err) = gSession.setImports(code)
  let elapsed = int((epochTime() - t0) * 1000)
  if err != "":
    send Response(id: req.id, kind: rkError, msg: err)
  else:
    send Response(id: req.id, kind: rkReady, cacheHit: false, elapsedMs: elapsed)

proc handleLoadProcs(req: Request) =
  send Response(id: req.id, kind: rkCompiling)
  let t0 = epochTime()
  let (_, err) = gSession.setProcs(req.procsCode)
  let elapsed = int((epochTime() - t0) * 1000)
  if err != "":
    send Response(id: req.id, kind: rkError, msg: err)
  else:
    send Response(id: req.id, kind: rkReloaded, elapsedMs: elapsed)

proc handleEval(req: Request) =
  let (stdout, err) = gSession.evalBlock(req.evalCode)
  if err != "":
    send Response(id: req.id, kind: rkError, msg: err)
  else:
    send Response(id: req.id, kind: rkResult, stdout: stdout, value: "")

proc handleComplete(req: Request) =
  # Placeholder — symbol completion from module graph is a future feature
  send Response(id: req.id, kind: rkCompletions, items: @[])

proc handleExit(req: Request) =
  send Response(id: req.id, kind: rkResult, stdout: "bye", value: "")
  stdout.flushFile()
  quit(0)

const Prompt = "nim> "

proc sendPrompt() =
  stdout.write("\n" & Prompt)
  stdout.flushFile()

proc main() =
  initGlobalSession()
  sendPrompt()
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
      of opExit:       handleExit(req)
    except:
      send Response(id: "?", kind: rkError, msg: getCurrentExceptionMsg())
    sendPrompt()

main()
