let jobCounter = (var x: int32 = 0; x.addr)

proc newBuffer(c: IFLContext) =
    jobCounter[] += 1
    let
        id = jobCounter[]
        buf = create(seq[uint8])
    buf[].setLen(BUFFER_SIZE)
    let o = imageflow_context_add_input_buffer(c.p,
                                               id,
                                               buf[][0].unsafeAddr,
                                               BUFFER_SIZE,
                                               imageflow_lifetime_lifetime_outlives_context)
    if not o:
        raise newException(Exception, "Could not add new job to imageflow context")

let jobs = create(Table[int, pointer])
jobs[] = initTable[int, pointer]()

proc newJob(c: IFLContext, id: int, j: JsonNode) =
    let
        json_str = cast[seq[uint8]](($j).cstring)
        json_pointer = json_str[0].unsafeAddr
        met = '/'
    let response = imageflow_context_send_json(c.p,
                                met.unsafeAddr,
                                json_pointer,
                                json_str.len.csize_t);
    c.check
    jobs[][id] = response

proc delete(c: IFLContext, id: int) {.inline.} =
    let b = imageflow_json_response_destroy(c.p, jobs[][id])
    if not b:
        raise newException(Exception, "Failed to destroy job id " & $id)
    jobs[].del(id)

proc get(c: IFLContext, id: int): seq[byte] =
    let
        status: int64 = 0
        output = create(seq[uint8])
    output[].setLen(BUFFER_SIZE)
    let output_ptr = create(ptr uint8)
    output_ptr[] = output[][0].unsafeAddr
    let size = BUFFER_SIZE.csize_t
    let b = imageflow_json_response_read(
        c.p,
        jobs[][id],
        status.unsafeAddr,
        cast[ptr ptr uint8](output),
        size.unsafeAddr
        )
    c.check
    if not b:
        raise newException(Exception, "Could not get response for job " & $id)
    return output[]
    # jobs[id]
