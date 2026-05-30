import binaryen from "binaryen";

// --- Module lifecycle -------------------------------------------------------

export const createModule = () => new binaryen.Module();

export const disposeImpl = (mod) => () => mod.dispose();

// --- Types ------------------------------------------------------------------

export const i32 = binaryen.i32;

export const i64 = binaryen.i64;

export const f32 = binaryen.f32;

export const f64 = binaryen.f64;

export const none = binaryen.none;

export const createType = (types) => binaryen.createType(types);

// --- Expression builders ----------------------------------------------------
// These allocate nodes in the module's arena, so they are modelled as Effect.

export const localGetImpl = (mod) => (index) => (ty) => () =>
  mod.local.get(index, ty);

export const localSetImpl = (mod) => (index) => (value) => () =>
  mod.local.set(index, value);

export const blockImpl = (mod) => (children) => (ty) => () =>
  mod.block(null, children, ty);

export const callImpl = (mod) => (target) => (operands) => (returnType) => () =>
  mod.call(target, operands, returnType);

export const i32AddImpl = (mod) => (left) => (right) => () =>
  mod.i32.add(left, right);

export const i32SubImpl = (mod) => (left) => (right) => () =>
  mod.i32.sub(left, right);

export const i32MulImpl = (mod) => (left) => (right) => () =>
  mod.i32.mul(left, right);

export const i32ConstImpl = (mod) => (value) => () =>
  mod.i32.const(value);

// --- Module mutation --------------------------------------------------------

export const addFunctionImpl =
  (mod) => (name) => (params) => (results) => (varTypes) => (body) => () =>
    mod.addFunction(name, params, results, varTypes, body);

export const addFunctionExportImpl =
  (mod) => (internalName) => (externalName) => () =>
    mod.addFunctionExport(internalName, externalName);

export const optimizeImpl = (mod) => () => mod.optimize();

// --- Validation & emission --------------------------------------------------

export const validateImpl = (mod) => () => mod.validate() !== 0;

export const emitTextImpl = (mod) => () => mod.emitText();

export const emitBinaryImpl = (mod) => () => mod.emitBinary();
