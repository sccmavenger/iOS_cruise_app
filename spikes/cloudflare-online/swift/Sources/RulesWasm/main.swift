// WebAssembly reactor exports. JavaScript writes a UTF-8 request into memory from cg_alloc,
// calls cg_call, then reads cg_out_len() bytes at the returned pointer and frees both.
import CruiseGameRules

nonisolated(unsafe) var lastOutputLength: Int32 = 0

@_expose(wasm, "cg_alloc")
func cgAlloc(_ size: Int32) -> Int32 {
    Int32(Int(bitPattern: UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)))
}

@_expose(wasm, "cg_free")
func cgFree(_ pointer: Int32) {
    UnsafeMutableRawPointer(bitPattern: Int(pointer))?.deallocate()
}

@_expose(wasm, "cg_out_len")
func cgOutLen() -> Int32 { lastOutputLength }

@_expose(wasm, "cg_call")
func cgCall(_ pointer: Int32, _ length: Int32) -> Int32 {
    let input = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: Int(pointer)), count: Int(length)), as: UTF8.self)
    let output = Array(Bridge.handle(input).utf8)
    let destination = UnsafeMutableRawPointer.allocate(byteCount: max(output.count, 1), alignment: 16)
    output.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: output.count) }
    lastOutputLength = Int32(output.count)
    return Int32(Int(bitPattern: destination))
}
