## JSON protocol types and I/O for the nimteractive server.
## All messages are single-line JSON terminated by newline.

import std/json

type
  OpKind* = enum
    opEval = "eval"
    opPrecompile = "precompile"
    opLoadProcs = "load_procs"
    opComplete = "complete"

  Request* = object
    id*: string
    case op*: OpKind
    of opEval:
      evalCode*: string
    of opPrecompile:
      imports*: seq[string]
    of opLoadProcs:
      procsCode*: string
    of opComplete:
      completeCode*: string
      cursor*: int

  ResponseKind* = enum
    rkResult, rkError, rkCompiling, rkReady, rkReloaded, rkCompletions

  Response* = object
    id*: string
    kind*: ResponseKind
    # rkResult
    stdout*: string
    value*: string
    # rkError
    msg*: string
    # rkReady / rkReloaded
    cacheHit*: bool
    elapsedMs*: int
    # rkCompletions
    items*: seq[string]

proc parseRequest*(line: string): Request =
  let j = parseJson(line)
  let op = j["op"].getStr
  let id = j["id"].getStr
  case op
  of "eval":
    result = Request(op: opEval, id: id, evalCode: j["code"].getStr)
  of "precompile":
    var imports: seq[string]
    for item in j["imports"]:
      imports.add item.getStr
    result = Request(op: opPrecompile, id: id, imports: imports)
  of "load_procs":
    result = Request(op: opLoadProcs, id: id, procsCode: j["code"].getStr)
  of "complete":
    result = Request(op: opComplete, id: id,
                     completeCode: j["code"].getStr,
                     cursor: j["cursor"].getInt)
  else:
    raise newException(ValueError, "unknown op: " & op)

proc toJson*(r: Response): JsonNode =
  result = %* {"id": r.id}
  case r.kind
  of rkResult:
    result["op"] = %"result"
    result["stdout"] = %r.stdout
    result["value"] = %r.value
  of rkError:
    result["op"] = %"error"
    result["msg"] = %r.msg
  of rkCompiling:
    result["op"] = %"compiling"
  of rkReady:
    result["op"] = %"ready"
    result["cache_hit"] = %r.cacheHit
    result["elapsed_ms"] = %r.elapsedMs
  of rkReloaded:
    result["op"] = %"reloaded"
    result["elapsed_ms"] = %r.elapsedMs
  of rkCompletions:
    result["op"] = %"completions"
    result["items"] = %r.items

proc send*(r: Response) =
  echo $r.toJson()
  stdout.flushFile()
