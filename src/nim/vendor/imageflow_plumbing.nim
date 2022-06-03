import ../cfg
import os

const imgfPrefix = when releaseMode: "." else: os.getenv("PROJECT_DIR", "../..")
const libimageflow = imgfPrefix & "/lib/libimageflow.so"

type
  imageflow_lifetime* = enum
    imageflow_lifetime_lifetime_outlives_function_call = 0,
    imageflow_lifetime_lifetime_outlives_context = 1

{.push cdecl, dynlib: libimageflow, importc.}
proc imageflow_abi_compatible*(imageflow_abi_ver_major: uint32;
                              imageflow_abi_ver_minor: uint32): bool
proc imageflow_abi_version_major*(): uint32
proc imageflow_abi_version_minor*(): uint32
proc imageflow_context_add_input_buffer*(context: pointer; io_id: int32;
                                        buffer: ptr uint8;
                                        buffer_byte_count: csize_t;
                                        lifetime: imageflow_lifetime): bool
proc imageflow_context_add_output_buffer*(context: pointer; io_id: int32): bool
proc imageflow_context_begin_terminate*(context: pointer): bool {.importc: "imageflow"}
proc imageflow_context_create*(imageflow_abi_ver_major: uint32;
                              imageflow_abi_ver_minor: uint32): pointer
proc imageflow_context_destroy*(context: pointer)
proc imageflow_context_error_as_exit_code*(context: pointer): int32
proc imageflow_context_error_as_http_code*(context: pointer): int32
proc imageflow_context_error_code*(context: pointer): int32
proc imageflow_context_error_recoverable*(context: pointer): bool
proc imageflow_context_error_try_clear*(context: pointer): bool
proc imageflow_context_error_write_to_buffer*(context: pointer; buffer: cstring;
    buffer_length: csize_t; bytes_written: ptr csize_t): bool
proc imageflow_context_get_output_buffer_by_id*(context: pointer; io_id: int32; 
    result_buffer: ptr ptr uint8; result_buffer_length: ptr csize_t): bool
proc imageflow_context_has_error*(context: pointer): bool
proc imageflow_context_memory_allocate*(context: pointer; bytes: csize_t;
                                       filename: cstring; line: int32): pointer
proc imageflow_context_memory_free*(context: pointer; pointer: pointer;
                                   filename: cstring; line: int32): bool
proc imageflow_context_print_and_exit_if_error*(context: pointer): bool
proc imageflow_context_send_json*(context: pointer; `method`: cstring;
                                 json_buffer: ptr uint8;
                                 json_buffer_size: csize_t): pointer
proc imageflow_json_response_destroy*(context: pointer; response: pointer): bool
proc imageflow_json_response_read*(context: pointer; response_in: pointer;
                                  status_as_http_code_out: ptr int64;
                                  buffer_utf8_no_nulls_out: ptr ptr uint8;
                                  buffer_size_out: ptr csize_t): bool
{.pop cdecl, dynlib: libimageflow, importc.}
