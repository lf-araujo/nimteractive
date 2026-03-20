## Procs hot-reload.
##
## When the user re-executes a :procs block, the procs section of the session
## buffer is replaced and the session is re-eval'd up to (but not including)
## the history. The module graph stays warm so imports are not re-paid.
## History is cleared because previously computed variables may depend on the
## old proc signatures.
##
## This is simpler and more correct than dlopen-based swapping because the
## procs live in the same VM context as eval blocks and can reference all
## imported symbols without any FFI boundary.

import nimteractive/session
export session.setProcs
