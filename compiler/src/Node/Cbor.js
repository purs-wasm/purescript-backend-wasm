import cbor from "cbor";

export const decodeAllImpl = async function (buf) {
  return await cbor.decodeAll(buf);
};

export const decodeFirstImpl = async function (buf) {
  return await cbor.decodeFirst(buf);
};

// EffectFn1: synchronous decode of the first CBOR value (may throw on malformed input).
export const decodeFirstSyncImpl = (buf) => cbor.decodeFirstSync(buf);
