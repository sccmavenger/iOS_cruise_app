// Loads the Swift rules (WebAssembly reactor) with a minimal WASI shim.
// The rules never touch files, so file calls fail cleanly; only randomness and the clock are real.
const ENOSYS = 52, EBADF = 8, SUCCESS = 0;

export function createRules(module) {
  let memory;
  const view = () => new DataView(memory.buffer);
  const bytes = () => new Uint8Array(memory.buffer);
  const logs = [];
  const wasi = {
    args_sizes_get: (argc, size) => { view().setUint32(argc, 0, true); view().setUint32(size, 0, true); return SUCCESS; },
    args_get: () => SUCCESS,
    environ_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return SUCCESS; },
    environ_get: () => SUCCESS,
    clock_res_get: (id, out) => { view().setBigUint64(out, 1000n, true); return SUCCESS; },
    clock_time_get: (id, precision, out) => { view().setBigUint64(out, BigInt(Date.now()) * 1000000n, true); return SUCCESS; },
    random_get: (pointer, length) => { crypto.getRandomValues(bytes().subarray(pointer, pointer + length)); return SUCCESS; },
    fd_write: (fd, iovs, count, written) => {
      let total = 0, text = "";
      for (let i = 0; i < count; i++) {
        const base = view().getUint32(iovs + i * 8, true), length = view().getUint32(iovs + i * 8 + 4, true);
        text += new TextDecoder().decode(bytes().subarray(base, base + length)); total += length;
      }
      if (fd === 1 || fd === 2) logs.push(text);
      view().setUint32(written, total, true);
      return SUCCESS;
    },
    fd_prestat_get: () => EBADF,
    fd_fdstat_get: (fd, out) => { if (fd > 2) return EBADF; bytes().fill(0, out, out + 24); view().setUint8(out, 2); return SUCCESS; },
    proc_exit: (code) => { throw new Error(`rules called proc_exit(${code}): ${logs.join("")}`); },
  };
  const imports = new Proxy(wasi, { get: (target, name) => target[name] ?? (() => ENOSYS) });
  const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: imports });
  memory = instance.exports.memory;
  instance.exports._initialize();
  const { cg_alloc, cg_free, cg_call, cg_out_len } = instance.exports;
  const encoder = new TextEncoder(), decoder = new TextDecoder();

  /** Sends one JSON request string to Swift and returns the JSON response string. */
  function callRaw(requestText) {
    const input = encoder.encode(requestText);
    const inPtr = cg_alloc(input.length);
    bytes().set(input, inPtr);
    const outPtr = cg_call(inPtr, input.length);
    const output = decoder.decode(bytes().slice(outPtr, outPtr + cg_out_len()));
    cg_free(inPtr); cg_free(outPtr);
    return output;
  }
  return { callRaw, call: (request) => JSON.parse(callRaw(JSON.stringify(request))), memory: () => memory.buffer.byteLength, logs };
}
