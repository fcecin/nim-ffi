## Regression: an `abi = c` entry point must survive a call from a host thread
## other than the one that first entered the library.
##
## The generated wrapper unpacks the request on the calling thread, which
## allocates via the Nim GC. Before the fix only the `{.ffiStatic.}` guard
## registered that thread, so method entries allocated on an unregistered one:
## harmless under orc, fatal under refc, which is the leg that matters here.

import std/[locks, os, osproc, strutils]
import unittest2
import results
import ffi

type ThreadLib = object
  tag: string

# Stub the dylib NimMain importc that declareLibrary emits (links as an exe).
{.emit: "void libthreadedcabiNimMain(void) {}".}

declareLibrary("threadedcabi", ThreadLib, defaultABIFormat = "c")

type ThreadConfig {.ffi.} = object
  tag: string

proc threadedcabi_create*(
    cfg: ThreadConfig
): Future[Result[ThreadLib, string]] {.ffiCtor.} =
  return ok(ThreadLib(tag: cfg.tag))

proc threadedcabi_echo*(
    lib: ThreadLib, text: string
): Future[Result[string, string]] {.ffi.} =
  ## Takes a string, so unpacking the request allocates on the calling thread.
  return ok(lib.tag & ":" & text)

genBindings()

type ReplyData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  text: string
  errMsg: string

proc initReplyData(d: var ReplyData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitReplyData(d: var ReplyData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc waitReply(d: var ReplyData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc onStringReply(
    err: cint, reply: cstring, errMsg: cstring, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr ReplyData](ud)
  acquire(d[].lock)
  if err == RET_OK and not reply.isNil():
    d[].text = $reply
  if err != RET_OK and not errMsg.isNil():
    d[].errMsg = $errMsg
  d[].retCode = err
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc packedWire[W, R](_: typedesc[W], envelope: R): W =
  var wire: W
  cwirePack(wire, envelope)
  wire

proc makeCtx(tag: string): ptr FFIContext[ThreadLib] =
  var d: ReplyData
  initReplyData(d)
  defer:
    deinitReplyData(d)

  var wire = packedWire(
    ThreadedcabiCreateCtorReq_CWire,
    ThreadedcabiCreateCtorReq(cfg: ThreadConfig(tag: tag)),
  )
  defer:
    cwireFree(wire)

  doAssert not ThreadedcabiCreateCtorReqCAbiExport(addr wire, onStringReply, addr d)
    .isNil()
  waitReply(d)
  doAssert d.retCode == RET_OK
  cast[ptr FFIContext[ThreadLib]](cast[uint](parseBiggestUInt(d.text)))

# The thread must be a foreign one, spawned by pthread_create. Nim's own
# `createThread` gives the new thread a GC heap on the way in, so a Nim thread
# cannot reproduce this: it is already registered.
{.
  emit: """/*INCLUDESECTION*/
#include <pthread.h>
"""
.}

{.
  emit: """
typedef int (*NimFfiEchoFn)(void*, void*, void*, const void*);

typedef struct {
  void* fn; void* ctx; void* cb; void* ud; const void* req; int ret;
} NimFfiForeignCall;

static void* nimffi_foreign_thread_main(void* arg) {
  NimFfiForeignCall* c = (NimFfiForeignCall*)arg;
  c->ret = ((NimFfiEchoFn)c->fn)(c->ctx, c->cb, c->ud, c->req);
  return (void*)0;
}

/* Calls `fn` on a thread Nim has never seen, and reports what it returned. */
int nimffi_call_on_pthread(void* fn, void* ctx, void* cb, void* ud, const void* req) {
  NimFfiForeignCall c;
  pthread_t t;
  c.fn = fn; c.ctx = ctx; c.cb = cb; c.ud = ud; c.req = req; c.ret = -1;
  if (pthread_create(&t, (void*)0, nimffi_foreign_thread_main, &c) != 0) return -2;
  pthread_join(t, (void*)0);
  return c.ret;
}
"""
.}

proc nimffi_call_on_pthread(
  fn, ctx, cb, ud: pointer, req: pointer
): cint {.importc, nodecl.}

proc callOnForeignThread(
    ctx: ptr FFIContext[ThreadLib], req: ptr ThreadedcabiEchoReq_CWire, d: ptr ReplyData
): cint =
  ## Passes the export's address to C as an opaque pointer instead of
  ## re-declaring it, so this cannot drift from the generated signature. The
  ## main thread packs the request, as a C host would, leaving the wrapper's
  ## own allocation as the thing under test.
  nimffi_call_on_pthread(
    cast[pointer](ThreadedcabiEchoReqCAbiExport),
    cast[pointer](ctx),
    cast[pointer](onStringReply),
    cast[pointer](d),
    cast[pointer](req),
  )

# ---------------------------------------------------------------------------
# child mode
#
# The risky call is made in a child process, not here. Before the fix it
# segfaults, and a segfault inside the test binary would kill the whole suite
# mid-run: no summary, no message, and a failure that reads like a flaky runner
# rather than "the guard is gone". Running it out of process turns that into an
# ordinary assertion on an exit status, and lets the rest of the suite finish.
# ---------------------------------------------------------------------------

const ChildFlag = "--foreign-thread-child"

proc childMain(mode: string): int =
  let ctx = makeCtx(if mode == "many": "pool" else: "worker")
  let rounds = if mode == "many": 8 else: 1

  for i in 0 ..< rounds:
    var d: ReplyData
    initReplyData(d)
    var req = packedWire(
      ThreadedcabiEchoReq_CWire,
      ThreadedcabiEchoReq(text: (if mode == "many": "call " & $i
        else: "once")),
    )

    let rc = callOnForeignThread(ctx, addr req, addr d)
    waitReply(d)
    let want = (if mode == "many": "pool:call " & $i else: "worker:once")
    let good = rc == RET_OK and d.retCode == RET_OK and d.text == want

    cwireFree(req)
    deinitReplyData(d)
    if not good:
      return 1

  if ThreadLibFFIPool.destroyFFIContext(ctx).isErr():
    return 1
  return 0

# Must run before unittest2 takes over, and never inside the parent.
let params = commandLineParams()
if params.len >= 2 and params[0] == ChildFlag:
  quit(childMain(params[1]))

proc runChild(mode: string): tuple[code: int, output: string] =
  # Run the binary directly and keep both streams, so a child failure explains
  # itself in the checkpoint rather than just showing an exit code.
  let cmd = quoteShell(getAppFilename()) & " " & ChildFlag & " " & mode & " 2>&1"
  let (outp, code) = execCmdEx(cmd)
  (code, outp)

suite "abi = c entry points are callable from foreign host threads":
  test "a method call from a second thread succeeds":
    let (code, outp) = runChild("single")
    checkpoint("child output: " & outp)
    check code == 0

  test "repeated calls from many distinct threads all succeed":
    ## Every fresh host thread arrives unregistered, so each one re-exercises
    ## the guard rather than riding on the first thread's registration.
    let (code, outp) = runChild("many")
    checkpoint("child output: " & outp)
    check code == 0
