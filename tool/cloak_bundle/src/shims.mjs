import { Buffer } from "buffer";

export { Buffer };
export const process = { env: {}, browser: true, version: "", versions: {}, nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)) };
