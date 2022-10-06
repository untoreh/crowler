when not defined(linux):
  raise newException(OSError, "Only linux is supported.")

import
  std/[os, osproc, streams, posix, hashes, strformat, locks],
  asynctools/asyncipc,
  std/exitprocs
import
  utils,
  translate_native
import chronos
import asyncdispatch except async, multisync, await, waitFor, Future,
    FutureBase, asyncSpawn, sleepAsync

const
  timeout = 1.seconds
  bufferSize = 1024 * 4
  maxProcessMem = 1024 * 1024 * 1024
var
  # Pipe and lock for to be translated text
  inputLock: ptr AsyncLock  # consumer is synchronous
  inputRecvIpc: ptr AsyncIpcHandle
  inputSendIpc: ptr AsyncIpcHandle
  # Pipe and lock for translated text
  outputLock: ptr AsyncLock # forwarder is synchronous
  outputSendIpc: ptr AsyncIpcHandle
  outputRecvIpc: ptr AsyncIpcHandle
  ipcInitialized = false

const
  appName = "translate_proc"
  ipcNameIn = "transInput"
  ipcNameOut = "transOuput"
  ipcSize = 10 * 1024 * 1024

proc setupIpc(name: string, force = false) =
  try:
    let ipc =
      try:
        createIpc(name, ipcSize)
      except OSError:
        if force:
          let path = getTempDir() / ("asyncipc_" & name)
          if not path.tryRemoveFile:
            raise newException(OSError, fmt"Couldn't create ipc bus {name}.")
          createIpc(name)
        else:
          raise newException(OSError, "Ipc file exists.")
    proc closeIpc() =
      close(ipc)
    {.cast(gcsafe).}:
      addExitProc(closeIpc)
  except OSError:
    discard

template connectSendIpc(prefix, name) =
  `prefix SendIpc`.maybeCreate(AsyncIpcHandle, false)
  `prefix SendIpc`[] = open(name, sideWriter, register = true)

template connectRecvIpc(prefix, name) =
  `prefix RecvIpc`.maybeCreate(AsyncIpcHandle, false)
  `prefix RecvIpc`[] = open(name, sideReader, register = true)

proc initIpc() {.gcsafe.} =
  info "Initializing IPC."
  inputLock = create(AsyncLock)
  inputLock[] = newAsyncLock()

  outputLock = create(AsyncLock)
  outputLock[] = newAsyncLock()

  setupIpc(ipcNameIn)
  setupIpc(ipcNameOut)

  connectRecvIpc(input, ipcNameIn) # translator recieve text to be translated
  connectSendIpc(input, ipcNameIn) # client sends text to be translated

  connectRecvIpc(output, ipcNameOut) # client receives translated text
  connectSendIpc(output, ipcNameOut) # server sends translated text
  ipcInitialized = true

proc waitLoop[T](fut: asyncdispatch.Future[T]) {.async.} =
  while not fut.finished():
    await sleepAsync(1.milliseconds)

proc wait(fut: asyncdispatch.Future[void], timeout = timeout) {.async.} =
  await waitLoop(fut).wait(timeout)

proc wait[T: not void](fut: asyncdispatch.Future[T], timeout = timeout): Future[T] {.async.} =
  await waitLoop(fut).wait(timeout)
  result = fut.read()

proc write(output: AsyncIpcHandle, s: string) {.async.} =
  if s.len == 0:
    return
  let header = s.len
  await output.write(header.unsafeAddr, sizeof(header)).wait
  await output.write(s[0].unsafeAddr, s.len).wait

proc read(input: AsyncIpcHandle, n: static int): Future[string] {.async.} =
  var dst: array[n, char]
  let c = await input.readInto(dst.addr, n).wait()
  return dst.toString

proc read(input: AsyncIpcHandle, timeout = 1.seconds): Future[
    string] {.async.} =
  # NOTE: read operation expect data *to be present in the pipe already*
  # if data is sent after the read is initiated, it stalls.
  # Read operations should always time-out.
  var size: array[sizeof(int), byte]
  var c = 0
  c = await input.readInto(size.addr, sizeof(int)).wait()
  if c != sizeof(int):
    raise newException(OSError, "Failed to read header from ipc.")
  let ln = cast[int](size)
  var dst = newSeq[byte](ln)
  c = await input.readInto(dst[0].addr, ln).wait()
  if c != ln:
    raise newException(OSError, "Failed to read content from ipc.")
  result.add dst.toOpenArray(0, c - 1).toString

proc read(input: AsyncIpcHandle, _: bool, buffer = bufferSize): Future[seq[
    byte]] {.async.} =
  var dst: array[bufferSize, byte]
  var c, n: int
  while true:
    c = await input.readInto(dst.addr, bufferSize).wait()
    n += c
    result.add dst.toOpenArray(0, n - 1)
    if c < bufferSize or result[^1].char == '\0':
      break

proc translateTask(text, src, trg: string) {.async.} =
  ## This translation task is run in a sub-process.
  var tries: int
  var translated: string
  var success: bool
  try:
    for _ in 0..3:
      try:
        translated.add await callService(text, src, trg)
        if translated.len == 0:
          continue
        success = true
        break
      except CatchableError as e:
        warn "{e[]}"
        if tries > 3:
          break
        tries.inc
  except Exception as e:
    echo e[]
    warn "trans: job failed, {src} -> {trg}."
  finally:
    let id = hash (text, src, trg)
    withAsyncLock(outputLock[]):
      await outputSendIpc[].write($id)
      await outputSendIpc[].write(translated)

proc restartTranslate() =
  warn "Restarting translate process..."
  let args = [getAppFilename()].allocCStringArray
  defer: dealloc(args)
  let success = execv(args[0], args)
  if success == -1:
    warn "Couldn't restart translate process, quitting {errno}."
    quit!()

template maybeRestart() =
  if unlikely(getOccupiedMem() > maxProcessMem):
    restartTranslate()

proc transConsumer() {.async.} =
  ## Sends translations on the ipc bus.
  try:
    info "Starting trans consumer..."
    var text, src, trg: string
    while true:
      try:
        # NOTE: order is text, src, trg
        text = await inputRecvIpc[].read()
        src = await inputRecvIpc[].read()
        trg = await inputRecvIpc[].read()
        debug "trans: disaptching translate task {src} -> {trg}."
        asyncSpawn translateTask(text, src, trg)
        maybeRestart()
      except AsyncTimeoutError:
        maybeRestart()
        continue
  except:
    let e = getCurrentException()[]
    warn "trans: consumer crashed. {e}"

proc transForwarderAsync() {.async.} =
  ## Forwards translated text from sub process to main proc translation table.
  info "Starting trans forwarder..."
  # var id, trans: string
  try:
    while true:
      try:
        let id = await outputRecvIpc[].read()
        let trans = await outputRecvIpc[].read()
        transOut[$id] = trans
      except AsyncTimeoutError:
        continue
  except:
    let e = getCurrentException()[]
    warn "trans: forwarder crashed. {e}"

proc findExe(): string =
  var exe: string
  var path = getCurrentDir()
  while true:
    exe = path / appName
    if fileExists(exe):
      return exe
    else:
      path = path.parentDir
      if path.len == 0:
        return "./" & appName

proc spawnAndMonitor() {.async.} =
  var p: Process
  let cmd = findExe()
  var loggerThread: Thread[Process]
  proc logger(p: Process) =
    let stream = p.peekableOutputStream
    defer: stream.close
    while p.running:
      let ln = stream.readLine
      info "translate_proc: {ln}"

  template start() =
    if p.isnil or not p.running:
      if not p.isnil:
        p.close
      p = startProcess(cmd, args = [])
      if loggerThread.running:
        joinThread(loggerThread)
      createThread(loggerThread, logger, p)
      proc reapProcess() =
        if p.running:
          terminate(p)
        discard p.waitForExit
        p.close
      {.cast(gcsafe).}:
        addExitProc(reapProcess)

  while true:
    try:
      start()
      while p.running:
        await sleepAsync(1.seconds)
    except CatchableError as e:
      warn "trans: process terminated. {e[]}"

proc transForwarderLoop() =
  var processMonitor: Future[void]
  while true:
    try:
      initIpc()
      if not processMonitor.isnil:
        processMonitor.complete()
        reset(processMonitor)
      processMonitor = spawnAndMonitor()
      waitFor transForwarderAsync()
    except:
      echo getCurrentException()[]
    sleep(1000)

proc transConsumerLoop() =
  while true:
    try:
      initIpc()
      waitFor transConsumer()
    except:
      echo getCurrentException()[]
    sleep(1000)

proc startTranslate*(server = false) =
  info "Setting up translation."
  setupTranslate()
  if server:
    transConsumerLoop()
  else:
    createThread(transThread, transForwarderLoop)
    while not ipcInitialized:
      sleep(1000)

proc translate*(text, src, trg: string): Future[string] {.async.} =
  # NOTE: order is text, src ,trg
  withAsyncLock(inputLock[]):
    await inputSendIpc[].write(text)
    await inputSendIpc[].write(src)
    await inputSendIpc[].write(trg)
  return waitTrans()


when isMainModule:
  import cligen
  when false:
    test()
  else:
    proc run() = startTranslate(true)
    dispatch run
