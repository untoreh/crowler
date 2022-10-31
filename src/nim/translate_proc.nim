when not defined(linux):
  raise newException(OSError, "Only linux is supported.")

import
  std/[os, osproc, streams, posix, hashes, strformat, parseutils, locks],
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
  transThread: Thread[void]
  futs {.threadvar}: seq[Future[void]]

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

proc write(output: AsyncIpcHandle, s: string | array) {.async.} =
  if s.len == 0:
    return
  let header = s.len
  await output.write(header.unsafeAddr, sizeof(header)).wait
  await output.write(s[0].unsafeAddr, s.len).wait

proc read(input: AsyncIpcHandle, n: static int): Future[string] {.async.} =
  var dst: array[n, char]
  let c = await input.readInto(dst.addr, n).wait()
  return dst[].toString

proc read[T](input: AsyncIpcHandle, dst: ptr T): Future[int] {.async.} =
  return await input.readInto(dst, dst[].len).wait()

proc read(input: AsyncIpcHandle, dst: pointer, n: static int): Future[int] {.async.} =
  return await input.readInto(dst, n).wait()

proc read(input: AsyncIpcHandle, timeout = 1.seconds): Future[string] {.async.} =
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

proc read[T](input: AsyncIpcHandle, dst: T,  _: bool, buffer = bufferSize): Future[seq[
    byte]] {.async.} =
  var c, n: int
  while true:
    c = await input.readInto(dst.addr, bufferSize).wait()
    n += c
    result.add dst.toOpenArray(0, n - 1)
    if c < bufferSize or result[^1].char == '\0':
      break

template read(input: AsyncIpcHandle, _: bool, buffer = bufferSize): Future[seq[byte]] =
  var dst: array[bufferSize, byte]
  read(input, _, dst, buffer)

template jobId(): int = (hash (text, src, trg)).int
template jobIdBytes(): array[sizeof(int), byte] =
  var idBytes: array[sizeof(int), byte]
  let id = jobId()
  copyMem(idBytes.addr, id.unsafeAddr, sizeof(int))
  idBytes

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
      except Exception:
        logexc()
        if tries > 3:
          break
        tries.inc
  except:
    logexc()
    warn "trans: job failed, {src} -> {trg}."
  finally:
    withAsyncLock(outputLock[]):
      await outputSendIpc[].write(jobIdBytes())
      await outputSendIpc[].write(translated)

proc restartTranslate() =
  warn "Restarting translate process..."
  let args = [getAppFilename()].allocCStringArray
  defer: dealloc(args)
  let success = execv(args[0], args)
  if success == -1:
    warn "Couldn't restart translate process, quitting {errno}."
    quitl()

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
        futs.add translateTask(text, src, trg)
        clearFuts(futs)
        maybeRestart()
      except AsyncTimeoutError:
        maybeRestart()
        continue
  except:
    logexc()
    warn "trans: consumer crashed."

proc transForwarderAsync() {.async.} =
  ## Forwards translated text from sub process to main proc translation table.
  info "Starting trans forwarder..."
  try:
    while true:
      try:
        var id: int
        let idBytes = (await outputRecvIpc[].read())
        copyMem(id.addr, idBytes[0].unsafeAddr, sizeof(int))
        let
          trText = await outputRecvIpc[].read()
          trans = create(string)
        trans[] = trText
        transOut[id] = trans
      except AsyncTimeoutError:
        await sleepAsync(1.millisecond)
        continue
  except:
    logexc()
    warn "trans: forwarder crashed."

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
    except Exception:
      logexc()
      warn "trans: process terminated."
    await sleepAsync(1.seconds)

proc transForwarderLoop() =
  var processMonitor: Future[void]
  while true:
    try:
      info "transForwarder: starting IPC..."
      initIpc()
      if not processMonitor.isnil:
        info "transForwarder: resetting process Monitor..."
        processMonitor.complete()
        reset(processMonitor)
      info "transForwarder: setting process Monitor..."
      processMonitor = spawnAndMonitor()
      info "transForwarder: starting forwarder..."
      waitFor transForwarderAsync()
    except:
      logexc()
    sleep(1000)

proc transConsumerLoop() =
  while true:
    try:
      initIpc()
      waitFor transConsumer()
    except:
      logexc()
    sleep(1000)

proc startTranslate*(worker = false) =
  info "Setting up translation."
  setupTranslate()
  if worker:
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
  result =
    block:
      let id = jobId()
      let v = await transOut.pop(id)
      defer: free(v)
      if v.isnil:
        ""
      else:
        v[]


when isMainModule:
  import cligen
  import nativehttp
  proc run() =
    initHttp()
    startTranslate(true)
  dispatch run
