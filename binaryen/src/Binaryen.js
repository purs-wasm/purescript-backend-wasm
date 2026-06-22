import binaryen from "binaryen";

// --- Module lifecycle -------------------------------------------------------

export const createModule = () => new binaryen.Module();

export const disposeImpl = (mod) => () => mod.dispose();

// Read a wasm binary back into a Module (the inverse of emitBinary). Used to post-process the
// merged wasm in the per-module build (ADR 0037): internalise resolved cross-module exports + opt.
export const readBinaryImpl = (bytes) => () => binaryen.readBinary(bytes);

// --- Types ------------------------------------------------------------------

export const i32 = binaryen.i32;

export const i64 = binaryen.i64;

export const f32 = binaryen.f32;

export const f64 = binaryen.f64;

export const none = binaryen.none;

export const auto = binaryen.auto;

export const createType = (types) => binaryen.createType(types);

// expose the actual expression type from binaryen
export const getExpressionType = (expr) => binaryen.getExpressionType(expr);

export const typeEq = (a) => (b) => a === b;

// --- Expression builders ----------------------------------------------------
// These allocate nodes in the module's arena, so they are modelled as Effect.

export const localGetImpl = (mod) => (index) => (ty) => () =>
  mod.local.get(index, ty);

export const localSetImpl = (mod) => (index) => (value) => () =>
  mod.local.set(index, value);

export const blockImpl = (mod) => (children) => (ty) => () =>
  mod.block(null, children, ty);

export const blockNamedImpl = (mod) => (name) => (children) => (ty) => () =>
  mod.block(name, children, ty);

export const loopImpl = (mod) => (label) => (body) => () =>
  mod.loop(label, body);

export const brImpl = (mod) => (label) => () => mod.br(label);

export const brIfImpl = (mod) => (label) => (condition) => () =>
  mod.br(label, condition);

export const brWithValueImpl = (mod) => (label) => (value) => () =>
  mod.br(label, undefined, value);

export const brIfWithValueImpl = (mod) => (label) => (condition) => (value) => () =>
  mod.br(label, condition, value);

export const callImpl = (mod) => (target) => (operands) => (returnType) => () =>
  mod.call(target, operands, returnType);

export const returnCallImpl = (mod) => (target) => (operands) => (returnType) => () =>
  mod.return_call(target, operands, returnType);

export const i32AddImpl = (mod) => (left) => (right) => () =>
  mod.i32.add(left, right);

export const i32SubImpl = (mod) => (left) => (right) => () =>
  mod.i32.sub(left, right);

export const i32MulImpl = (mod) => (left) => (right) => () =>
  mod.i32.mul(left, right);

export const i32DivSImpl = (mod) => (left) => (right) => () =>
  mod.i32.div_s(left, right);

export const i32RemSImpl = (mod) => (left) => (right) => () =>
  mod.i32.rem_s(left, right);

export const i32EqImpl = (mod) => (left) => (right) => () =>
  mod.i32.eq(left, right);

export const i32LtUImpl = (mod) => (left) => (right) => () =>
  mod.i32.lt_u(left, right);

export const i32LtSImpl = (mod) => (left) => (right) => () =>
  mod.i32.lt_s(left, right);

export const i32AndImpl = (mod) => (left) => (right) => () =>
  mod.i32.and(left, right);

export const i32OrImpl = (mod) => (left) => (right) => () =>
  mod.i32.or(left, right);

export const i32XorImpl = (mod) => (left) => (right) => () =>
  mod.i32.xor(left, right);

export const i32ShlImpl = (mod) => (left) => (right) => () =>
  mod.i32.shl(left, right);

export const i32ShrSImpl = (mod) => (left) => (right) => () =>
  mod.i32.shr_s(left, right);

export const i32ShrUImpl = (mod) => (left) => (right) => () =>
  mod.i32.shr_u(left, right);

export const i32EqzImpl = (mod) => (value) => () =>
  mod.i32.eqz(value);

export const i32NeImpl = (mod) => (left) => (right) => () =>
  mod.i32.ne(left, right);

export const i64AndImpl = (mod) => (left) => (right) => () =>
  mod.i64.and(left, right);

export const i64OrImpl = (mod) => (left) => (right) => () =>
  mod.i64.or(left, right);

export const i64XorImpl = (mod) => (left) => (right) => () =>
  mod.i64.xor(left, right);

export const i64ShlImpl = (mod) => (left) => (right) => () =>
  mod.i64.shl(left, right);

export const i64ShrSImpl = (mod) => (left) => (right) => () =>
  mod.i64.shr_s(left, right);

export const i64ShrUImpl = (mod) => (left) => (right) => () =>
  mod.i64.shr_u(left, right);

export const i64RotLImpl = (mod) => (left) => (right) => () =>
  mod.i64.rotl(left, right);

export const i64RotRImpl = (mod) => (left) => (right) => () =>
  mod.i64.rotr(left, right);

export const i64EqImpl = (mod) => (left) => (right) => () =>
  mod.i64.eq(left, right);

export const i64LtSImpl = (mod) => (left) => (right) => () =>
  mod.i64.lt_s(left, right);

export const i64ExtendI32SImpl = (mod) => (value) => () =>
  mod.i64.extend_s(value);

export const i32WrapI64Impl = (mod) => (value) => () =>
  mod.i32.wrap(value);

export const ifImpl = (mod) => (cond) => (ifTrue) => (ifFalse) => () =>
  mod.if(cond, ifTrue, ifFalse);

export const unreachableImpl = (mod) => () => mod.unreachable();

export const i64ConstImpl = (mod) => (low) => (high) => () =>
  mod.i64.const(low, high);

export const i32ConstImpl = (mod) => (value) => () =>
  mod.i32.const(value);

export const i32TruncF64SImpl = (mod) => (value) => () =>
  mod.i32.trunc_s.f64(value);

export const f64ConstImpl = (mod) => (value) => () =>
  mod.f64.const(value);

export const f64EqImpl = (mod) => (left) => (right) => () =>
  mod.f64.eq(left, right);

export const f64LtImpl = (mod) => (left) => (right) => () =>
  mod.f64.lt(left, right);

export const f64AddImpl = (mod) => (left) => (right) => () => mod.f64.add(left, right);
export const f64SubImpl = (mod) => (left) => (right) => () => mod.f64.sub(left, right);
export const f64MulImpl = (mod) => (left) => (right) => () => mod.f64.mul(left, right);
export const f64DivImpl = (mod) => (left) => (right) => () => mod.f64.div(left, right);

export const f64ConvertI32SImpl = (mod) => (value) => () =>
  mod.f64.convert_s.i32(value);

// --- Wasm GC (raw emscripten C API) -----------------------------------------
// Binaryen.js 123 ships no high-level GC builders, so we call the raw C API and
// marshal arrays through the emscripten heap ourselves. Expression/Type/HeapType
// "refs" are all plain integers (C pointers/handles), so they pass through FFI
// as-is and interoperate with the high-level builders above.

export const eqref = binaryen.eqref;

export const funcref = binaryen.funcref;

export const i31ref = binaryen.i31ref;

export const i31NewImpl = (mod) => (value) => () => mod.ref.i31(value);

export const i31GetSImpl = (mod) => (value) => () => mod.i31.get_s(value);

export const setFeaturesGC = (mod) => () => {
  mod.setFeatures(
    binaryen.Features.GC | binaryen.Features.ReferenceTypes | binaryen.Features.TailCall,
  );
};

// Write an array of 32-bit values into a freshly malloc'd buffer; caller frees.
const mallocI32 = (values) => {
  const ptr = binaryen._malloc(Math.max(1, values.length) * 4);
  for (let i = 0; i < values.length; i++) binaryen.HEAP32[(ptr >> 2) + i] = values[i];
  return ptr;
};

// `bool` is one byte in the C ABI, so mutability arrays go through HEAPU8.
const mallocBool = (values) => {
  const ptr = binaryen._malloc(Math.max(1, values.length));
  for (let i = 0; i < values.length; i++) binaryen.HEAPU8[ptr + i] = values[i] ? 1 : 0;
  return ptr;
};

export const typeBuilderCreate = (size) => () => binaryen._TypeBuilderCreate(size);

export const typeBuilderSetStructType = (tb) => (index) => (fields) => () => {
  const notPacked = binaryen._BinaryenPackedTypeNotPacked();
  const types = mallocI32(fields.map((f) => f.ty));
  const packed = mallocI32(fields.map(() => notPacked));
  const muts = mallocBool(fields.map((f) => f.mutable));
  binaryen._TypeBuilderSetStructType(tb, index, types, packed, muts, fields.length);
  binaryen._free(types);
  binaryen._free(packed);
  binaryen._free(muts);
};

export const typeBuilderSetArrayType = (tb) => (index) => (elementType) => (mutable) => () => {
  const notPacked = binaryen._BinaryenPackedTypeNotPacked();
  binaryen._TypeBuilderSetArrayType(tb, index, elementType, notPacked, mutable ? 1 : 0);
};

export const typeBuilderSetSignatureType = (tb) => (index) => (params) => (results) => () =>
  binaryen._TypeBuilderSetSignatureType(tb, index, params, results);

// Mark a builder slot as "open" (extensible) so other slots may declare it as a
// supertype — closed/final is the default in the GC type system.
export const typeBuilderSetOpen = (tb) => (index) => () =>
  binaryen._TypeBuilderSetOpen(tb, index);

// Declare the slot at `index` to be a subtype of `supertype` (a temp heap type
// from the same builder, e.g. `typeBuilderGetTempHeapType`).
export const typeBuilderSetSubType = (tb) => (index) => (supertype) => () =>
  binaryen._TypeBuilderSetSubType(tb, index, supertype);

export const typeBuilderGetTempHeapType = (tb) => (index) => () =>
  binaryen._TypeBuilderGetTempHeapType(tb, index);

export const typeBuilderGetTempRefType = (tb) => (ht) => (nullable) => () =>
  binaryen._TypeBuilderGetTempRefType(tb, ht, nullable ? 1 : 0);

export const typeBuilderBuildAndDispose = (tb) => (size) => () => {
  const htsPtr = binaryen._malloc(Math.max(1, size) * 4);
  const errIndexPtr = binaryen._malloc(4);
  const errReasonPtr = binaryen._malloc(4);
  const ok = binaryen._TypeBuilderBuildAndDispose(tb, htsPtr, errIndexPtr, errReasonPtr);
  if (!ok) {
    const idx = binaryen.HEAP32[errIndexPtr >> 2];
    const reason = binaryen.HEAP32[errReasonPtr >> 2];
    binaryen._free(htsPtr);
    binaryen._free(errIndexPtr);
    binaryen._free(errReasonPtr);
    throw new Error("Binaryen TypeBuilder failed at slot " + idx + " (reason " + reason + ")");
  }
  const out = [];
  for (let i = 0; i < size; i++) out.push(binaryen.HEAP32[(htsPtr >> 2) + i]);
  binaryen._free(htsPtr);
  binaryen._free(errIndexPtr);
  binaryen._free(errReasonPtr);
  return out;
};

export const typeFromHeapType = (ht) => (nullable) =>
  binaryen._BinaryenTypeFromHeapType(ht, nullable ? 1 : 0);

export const structNew = (mod) => (ht) => (operands) => () => {
  const ptr = mallocI32(operands);
  const expr = binaryen._BinaryenStructNew(mod.ptr, ptr, operands.length, ht);
  binaryen._free(ptr);
  return expr;
};

export const structGet = (mod) => (index) => (ref) => (ty) => (signed) => () =>
  binaryen._BinaryenStructGet(mod.ptr, index, ref, ty, signed ? 1 : 0);

export const arrayNew = (mod) => (ht) => (size) => (init) => () =>
  binaryen._BinaryenArrayNew(mod.ptr, ht, size, init);

export const arrayNewDefault = (mod) => (ht) => (size) => () =>
  binaryen._BinaryenArrayNewDefault(mod.ptr, ht, size);

export const refNull = (mod) => (ht) => () =>
  binaryen._BinaryenRefNull(mod.ptr, ht);

export const arrayNewFixed = (mod) => (ht) => (values) => () => {
  const ptr = mallocI32(values);
  const expr = binaryen._BinaryenArrayNewFixed(mod.ptr, ht, ptr, values.length);
  binaryen._free(ptr);
  return expr;
};

export const arrayGet = (mod) => (ref) => (index) => (ty) => (signed) => () =>
  binaryen._BinaryenArrayGet(mod.ptr, ref, index, ty, signed ? 1 : 0);

export const arraySet = (mod) => (ref) => (index) => (value) => () =>
  binaryen._BinaryenArraySet(mod.ptr, ref, index, value);

export const arrayLen = (mod) => (ref) => () =>
  binaryen._BinaryenArrayLen(mod.ptr, ref);

export const arrayCopy = (mod) => (dest) => (destIndex) => (src) => (srcIndex) => (length) => () =>
  binaryen._BinaryenArrayCopy(mod.ptr, dest, destIndex, src, srcIndex, length);

export const refCast = (mod) => (ref) => (ty) => () =>
  binaryen._BinaryenRefCast(mod.ptr, ref, ty);

// ref.func takes the function name as a C string, so go through the high-level
// binaryen.js method which marshals it (the raw _BinaryenRefFunc would need the
// string copied into the emscripten heap).
export const refFunc = (mod) => (name) => (ht) => () => mod.ref.func(name, ht);

export const callRef = (mod) => (target) => (operands) => (ht) => () => {
  const ptr = mallocI32(operands);
  const expr = binaryen._BinaryenCallRef(mod.ptr, target, ptr, operands.length, ht, false);
  binaryen._free(ptr);
  return expr;
};

// --- Module mutation --------------------------------------------------------

export const addFunctionImpl =
  (mod) => (name) => (params) => (results) => (varTypes) => (body) => () =>
    mod.addFunction(name, params, results, varTypes, body);

export const addFunctionExportImpl =
  (mod) => (internalName) => (externalName) => () =>
    mod.addFunctionExport(internalName, externalName);

// Remove an export by its external name (internalise it). Used after wasm-merge resolves a
// cross-module function export, so the now-redundant export no longer pins the function (ADR 0037).
export const removeExportImpl = (mod) => (externalName) => () => mod.removeExport(externalName);

// Set the module's start function (run automatically at instantiation).
export const setStartImpl = (mod) => (fn) => () => mod.setStart(fn);

export const addFunctionImportImpl =
  (mod) => (internalName) => (externalModule) => (externalBase) => (params) => (results) => () =>
    mod.addFunctionImport(internalName, externalModule, externalBase, params, results);

export const addGlobalImpl =
  (mod) => (name) => (type) => (mutable) => (init) => () =>
    mod.addGlobal(name, type, mutable, init);

export const globalGetImpl = (mod) => (name) => (type) => () =>
  mod.global.get(name, type);

export const globalSetImpl = (mod) => (name) => (value) => () =>
  mod.global.set(name, value);

export const optimizeImpl = (mod) => () => mod.optimize();

// Run a specific list of optimization passes (rather than the full `-O` pipeline). Used post-merge
// to DCE internalised cross-module exports cheaply (`remove-unused-module-elements`) without the
// cost of re-optimising the whole merged module (ADR 0037 Phase 3).
export const runPassesImpl = (mod) => (passes) => () => mod.runPasses(passes);

// --- Validation & emission --------------------------------------------------

export const validateImpl = (mod) => () => mod.validate() !== 0;

export const emitTextImpl = (mod) => () => mod.emitText();

export const emitBinaryImpl = (mod) => () => mod.emitBinary();