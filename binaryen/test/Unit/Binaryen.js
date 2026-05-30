export const byteLength = (bytes) => bytes.length;

export const magicPrefix = (bytes) => Array.from(bytes.slice(0, 4));
