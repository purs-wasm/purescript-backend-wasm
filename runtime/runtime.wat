;; The shared runtime (ADR 0010). Hand-written WAT, assembled to runtime.wasm by
;; Binaryen's wasm-as. Generated programs IMPORT these `$rt.*` helpers from module
;; "rt"; the test harness wires them at instantiation, and `bin` merges them in
;; with wasm-merge for a single self-contained wasm.
;;
;; The value types below MUST match the compiler's `buildRuntimeTypes` (Codegen.purs)
;; structurally. They are declared as INDIVIDUAL types (NOT wrapped in `(rec …)`):
;; the value rec-group is acyclic, so Binaryen emits each generated type as its own
;; singleton rec group, and a singleton `$Str` is a *different* canonical type from a
;; `$Str` that is a member of a multi-type `(rec …)`. Declaring them individually
;; here makes both sides canonicalize identically, so a `$Str`/`$Vals`/… built by a
;; generated module survives `ref.cast` across the import boundary (ADR 0010 spike).
;; Only the types the helpers actually touch are declared. The helpers' *signatures*
;; use only eqref/i32 (ADR 0004); concrete GC types appear only inside the bodies.
(module
  (type $Vals (array (mut eqref)))                                  ;; array elements / record values
  (type $LabelIds (array (mut i32)))                                ;; interned record labels (mut: rebuilt by recSet/recDelete)
  (type $Bytes (array (mut i32)))                                   ;; UTF-8 bytes, one per i32 lane (not packed)
  (type $Rec (struct (field (ref $LabelIds)) (field (ref $Vals))))  ;; parallel labels / values
  (type $Str (struct (field (ref $Bytes))))
  (type $Int (struct (field i32)))                                  ;; boxed Int (also Char)
  (type $Num (struct (field f64)))                                  ;; boxed Number (host marshals nested f64)
  (type $Clo (struct (field funcref) (field (ref $Vals))))          ;; closure: code + captured env
  (type $Code (func (param (ref $Clo) eqref) (result eqref)))       ;; lifted closure-body signature
  (type $Ref (struct (field (mut eqref))))                          ;; Effect.Ref / ST.STRef: a single mutable cell (ADR 0017)

  ;; $rt.proj(rec, target) -> eqref : linear-search the record's interned label-id
  ;; array for `target`, returning the parallel value (ADR 0007). Records are never
  ;; empty, so the first read needs no bound check; exhausting the array traps (the
  ;; label was absent — a compile-time impossibility).
  (func $rt.proj (export "proj") (param $rec eqref) (param $target i32) (result eqref)
    (local $r (ref $Rec))
    (local $i i32)
    (local.set $r (ref.cast (ref $Rec) (local.get $rec)))
    (block $found (result eqref)
      (loop $loop
        (if (i32.eq (array.get $LabelIds (struct.get $Rec 0 (local.get $r)) (local.get $i))
                    (local.get $target))
          (then (br $found (array.get $Vals (struct.get $Rec 1 (local.get $r)) (local.get $i)))))
        (br_if $loop
          (i32.lt_u (local.tee $i (i32.add (local.get $i) (i32.const 1)))
                    (array.len (struct.get $Rec 0 (local.get $r)))))
        (unreachable))
      (unreachable)))

  ;; $rt.recHas(rec, id) -> i32 : 1 iff the record has a field with label id `id`
  ;; (Record.Unsafe's `unsafeHas`; non-trapping, unlike `proj`, and empty-safe).
  (func $rt.recHas (export "recHas") (param $rec eqref) (param $id i32) (result i32)
    (local $ids (ref $LabelIds))
    (local $n i32)
    (local $i i32)
    (local.set $ids (struct.get $Rec 0 (ref.cast (ref $Rec) (local.get $rec))))
    (local.set $n (array.len (local.get $ids)))
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.eq (array.get $LabelIds (local.get $ids) (local.get $i)) (local.get $id))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (i32.const 0))

  ;; $rt.recSet(rec, id, val) -> eqref : Record.Unsafe's `unsafeSet`. Label ids are
  ;; kept sorted ascending, so we find the first position `pos` with id[pos] >= id;
  ;; if it equals `id` the field is replaced (copy, swap that value), otherwise the
  ;; (id, val) pair is inserted there (fresh length+1 arrays). Pure: the input record
  ;; is never mutated.
  (func $rt.recSet (export "recSet") (param $rec eqref) (param $id i32) (param $val eqref) (result eqref)
    (local $r (ref $Rec))
    (local $ids (ref $LabelIds))
    (local $vals (ref $Vals))
    (local $n i32)
    (local $pos i32)
    (local $nids (ref $LabelIds))
    (local $nvals (ref $Vals))
    (local.set $r (ref.cast (ref $Rec) (local.get $rec)))
    (local.set $ids (struct.get $Rec 0 (local.get $r)))
    (local.set $vals (struct.get $Rec 1 (local.get $r)))
    (local.set $n (array.len (local.get $ids)))
    (block $stop
      (loop $loop
        (br_if $stop (i32.ge_u (local.get $pos) (local.get $n)))
        (br_if $stop (i32.ge_u (array.get $LabelIds (local.get $ids) (local.get $pos)) (local.get $id)))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $loop)))
    ;; replace: pos in range and the id already present. The bounds check must
    ;; short-circuit — `i32.and` evaluates both operands, so a single `and` would
    ;; still execute `ids[pos]` when `pos == n` (e.g. an empty record), reading out
    ;; of bounds. Nesting guards the `array.get` behind the range test.
    (if (i32.lt_u (local.get $pos) (local.get $n))
      (then
        (if (i32.eq (array.get $LabelIds (local.get $ids) (local.get $pos)) (local.get $id))
          (then
            (local.set $nids (array.new $LabelIds (i32.const 0) (local.get $n)))
            (array.copy $LabelIds $LabelIds (local.get $nids) (i32.const 0) (local.get $ids) (i32.const 0) (local.get $n))
            (local.set $nvals (array.new $Vals (ref.null none) (local.get $n)))
            (array.copy $Vals $Vals (local.get $nvals) (i32.const 0) (local.get $vals) (i32.const 0) (local.get $n))
            (array.set $Vals (local.get $nvals) (local.get $pos) (local.get $val))
            (return (struct.new $Rec (local.get $nids) (local.get $nvals)))))))
    ;; insert at pos: [0,pos) copied, [pos] new, [pos,n) shifted right by one
    (local.set $nids (array.new $LabelIds (i32.const 0) (i32.add (local.get $n) (i32.const 1))))
    (local.set $nvals (array.new $Vals (ref.null none) (i32.add (local.get $n) (i32.const 1))))
    (array.copy $LabelIds $LabelIds (local.get $nids) (i32.const 0) (local.get $ids) (i32.const 0) (local.get $pos))
    (array.copy $Vals $Vals (local.get $nvals) (i32.const 0) (local.get $vals) (i32.const 0) (local.get $pos))
    (array.set $LabelIds (local.get $nids) (local.get $pos) (local.get $id))
    (array.set $Vals (local.get $nvals) (local.get $pos) (local.get $val))
    ;; shift the tail [pos,n) right by one — only when there IS a tail. Appending at
    ;; the end (pos == n, e.g. building from `recEmpty`) would otherwise issue an
    ;; `array.copy` with dest_offset == new length and len 0, which V8 traps on at the
    ;; boundary despite the spec permitting it.
    (if (i32.lt_u (local.get $pos) (local.get $n))
      (then
        (array.copy $LabelIds $LabelIds (local.get $nids) (i32.add (local.get $pos) (i32.const 1)) (local.get $ids) (local.get $pos) (i32.sub (local.get $n) (local.get $pos)))
        (array.copy $Vals $Vals (local.get $nvals) (i32.add (local.get $pos) (i32.const 1)) (local.get $vals) (local.get $pos) (i32.sub (local.get $n) (local.get $pos)))))
    (struct.new $Rec (local.get $nids) (local.get $nvals)))

  ;; $rt.recDelete(rec, id) -> eqref : Record.Unsafe's `unsafeDelete`. Returns the
  ;; record unchanged if the label is absent, else fresh length-1 arrays omitting it.
  (func $rt.recDelete (export "recDelete") (param $rec eqref) (param $id i32) (result eqref)
    (local $r (ref $Rec))
    (local $ids (ref $LabelIds))
    (local $vals (ref $Vals))
    (local $n i32)
    (local $pos i32)
    (local $rest i32)
    (local $nids (ref $LabelIds))
    (local $nvals (ref $Vals))
    (local.set $r (ref.cast (ref $Rec) (local.get $rec)))
    (local.set $ids (struct.get $Rec 0 (local.get $r)))
    (local.set $vals (struct.get $Rec 1 (local.get $r)))
    (local.set $n (array.len (local.get $ids)))
    (if (i32.eqz (local.get $n)) (then (return (local.get $rec))))
    (block $found
      (loop $loop
        (br_if $found (i32.eq (array.get $LabelIds (local.get $ids) (local.get $pos)) (local.get $id)))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br_if $loop (i32.lt_u (local.get $pos) (local.get $n)))
        (return (local.get $rec))))
    ;; omit index pos: [0,pos) copied, (pos,n) shifted left by one
    (local.set $rest (i32.sub (i32.sub (local.get $n) (local.get $pos)) (i32.const 1)))
    (local.set $nids (array.new $LabelIds (i32.const 0) (i32.sub (local.get $n) (i32.const 1))))
    (local.set $nvals (array.new $Vals (ref.null none) (i32.sub (local.get $n) (i32.const 1))))
    (array.copy $LabelIds $LabelIds (local.get $nids) (i32.const 0) (local.get $ids) (i32.const 0) (local.get $pos))
    (array.copy $Vals $Vals (local.get $nvals) (i32.const 0) (local.get $vals) (i32.const 0) (local.get $pos))
    (array.copy $LabelIds $LabelIds (local.get $nids) (local.get $pos) (local.get $ids) (i32.add (local.get $pos) (i32.const 1)) (local.get $rest))
    (array.copy $Vals $Vals (local.get $nvals) (local.get $pos) (local.get $vals) (i32.add (local.get $pos) (i32.const 1)) (local.get $rest))
    (struct.new $Rec (local.get $nids) (local.get $nvals)))

  ;; $rt.strEq(a, b) -> i32 : 1 iff the two strings have equal bytes.
  (func $rt.strEq (export "strEq") (param $a eqref) (param $b eqref) (result i32)
    (local $ba (ref $Bytes))
    (local $bb (ref $Bytes))
    (local $len i32)
    (local $i i32)
    (local.set $ba (struct.get $Str 0 (ref.cast (ref $Str) (local.get $a))))
    (local.set $bb (struct.get $Str 0 (ref.cast (ref $Str) (local.get $b))))
    (local.set $len (array.len (local.get $ba)))
    (if (i32.ne (local.get $len) (array.len (local.get $bb)))
      (then (return (i32.const 0))))
    (block $done
      (loop $loop
        (br_if $done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.ne (array.get $Bytes (local.get $ba) (local.get $i))
                    (array.get $Bytes (local.get $bb) (local.get $i)))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (i32.const 1))

  ;; Read access to a $Str's bytes — exported for the test harness so JS can read a
  ;; rendered string back out (GC arrays are otherwise opaque to JS).
  (func $strLen (export "strLen") (param $s eqref) (result i32)
    (array.len (struct.get $Str 0 (ref.cast (ref $Str) (local.get $s)))))
  (func $strByteAt (export "strByteAt") (param $s eqref) (param $i i32) (result i32)
    (array.get $Bytes (struct.get $Str 0 (ref.cast (ref $Str) (local.get $s))) (local.get $i)))

  ;; Build access to a $Str from the host (ADR 0014, FFI string marshalling): JS
  ;; cannot allocate GC structs, so it makes a zeroed $Str of `len` UTF-8 bytes with
  ;; strNew, fills it byte by byte with strSetByte, and hands the result to wasm.
  (func $strNew (export "strNew") (param $len i32) (result eqref)
    (struct.new $Str (array.new $Bytes (i32.const 0) (local.get $len))))
  (func $strSetByte (export "strSetByte") (param $s eqref) (param $i i32) (param $b i32)
    (array.set $Bytes (struct.get $Str 0 (ref.cast (ref $Str) (local.get $s))) (local.get $i) (local.get $b)))

  ;; Array ($Vals) access for FFI marshalling (ADR 0014): len/get to read a wasm
  ;; array into a JS array, new/set to build one from JS. Elements are boxed eqrefs
  ;; (the array is homogeneous), so the host marshals each element recursively.
  (func $arrayLen (export "arrayLen") (param $a eqref) (result i32)
    (array.len (ref.cast (ref $Vals) (local.get $a))))
  (func $arrayGet (export "arrayGet") (param $a eqref) (param $i i32) (result eqref)
    (array.get $Vals (ref.cast (ref $Vals) (local.get $a)) (local.get $i)))
  (func $arrayNew (export "arrayNew") (param $len i32) (result eqref)
    (array.new $Vals (ref.null none) (local.get $len)))
  (func $arraySet (export "arraySet") (param $a eqref) (param $i i32) (param $v eqref)
    (array.set $Vals (ref.cast (ref $Vals) (local.get $a)) (local.get $i) (local.get $v)))

  ;; Box / unbox a $Int — the host marshals a boxed Int array element / record field
  ;; to a JS number and back.
  (func $boxInt (export "boxInt") (param $n i32) (result eqref)
    (struct.new $Int (local.get $n)))
  (func $unboxInt (export "unboxInt") (param $b eqref) (result i32)
    (struct.get $Int 0 (ref.cast (ref $Int) (local.get $b))))

  ;; Box / unbox a $Num — the host marshals a boxed Number array element / record
  ;; field to a JS number and back (a top-level Number crosses as a raw f64 instead).
  (func $boxNum (export "boxNum") (param $n f64) (result eqref)
    (struct.new $Num (local.get $n)))
  (func $unboxNum (export "unboxNum") (param $b eqref) (result f64)
    (struct.get $Num 0 (ref.cast (ref $Num) (local.get $b))))

  ;; Box / unbox a Boolean — represented as an `i31ref` (true = 1, false = 0; ADR
  ;; 0001), so the host marshals it to/from a JS boolean (both top-level and nested).
  (func $boxBool (export "boxBool") (param $n i32) (result eqref)
    (ref.i31 (local.get $n)))
  (func $unboxBool (export "unboxBool") (param $b eqref) (result i32)
    (i31.get_s (ref.cast i31ref (local.get $b))))

  ;; An empty record ($Rec): the host builds a record by `recSet`ting fields onto it
  ;; (keyed by interned label id). Read access reuses $rt.proj (ADR 0014).
  (func $recEmpty (export "recEmpty") (result eqref)
    (struct.new $Rec (array.new_fixed $LabelIds 0) (array.new_fixed $Vals 0)))

  ;; $rt.strCmp(a, b) -> i32 (-1 / 0 / 1): lexicographic byte comparison. On UTF-8
  ;; bytes this is code-point order (UTF-8 preserves it); it diverges from JS's
  ;; UTF-16 order only for strings mixing astral characters with U+E000..U+FFFF
  ;; (a documented consequence of the UTF-8 string representation, ADR 0001).
  (func $rt.strCmp (export "strCmp") (param $a eqref) (param $b eqref) (result i32)
    (local $ba (ref $Bytes))
    (local $bb (ref $Bytes))
    (local $la i32)
    (local $lb i32)
    (local $i i32)
    (local $ca i32)
    (local $cb i32)
    (local.set $ba (struct.get $Str 0 (ref.cast (ref $Str) (local.get $a))))
    (local.set $bb (struct.get $Str 0 (ref.cast (ref $Str) (local.get $b))))
    (local.set $la (array.len (local.get $ba)))
    (local.set $lb (array.len (local.get $bb)))
    (block $done (result i32)
      (loop $loop
        ;; one string exhausted: the shorter (prefix) is smaller
        (if (i32.or (i32.ge_u (local.get $i) (local.get $la)) (i32.ge_u (local.get $i) (local.get $lb)))
          (then (br $done
            (if (result i32) (i32.lt_u (local.get $la) (local.get $lb)) (then (i32.const -1))
              (else (if (result i32) (i32.gt_u (local.get $la) (local.get $lb)) (then (i32.const 1)) (else (i32.const 0))))))))
        (local.set $ca (array.get $Bytes (local.get $ba) (local.get $i)))
        (local.set $cb (array.get $Bytes (local.get $bb) (local.get $i)))
        (if (i32.ne (local.get $ca) (local.get $cb))
          (then (br $done (if (result i32) (i32.lt_u (local.get $ca) (local.get $cb)) (then (i32.const -1)) (else (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop))))

  ;; $rt.strConcat(a, b) -> eqref : allocate a byte array of the combined length and
  ;; array.copy both halves in.
  (func $rt.strConcat (export "strConcat") (param $a eqref) (param $b eqref) (result eqref)
    (local $ba (ref $Bytes))
    (local $bb (ref $Bytes))
    (local $lenA i32)
    (local $dest (ref $Bytes))
    (local.set $ba (struct.get $Str 0 (ref.cast (ref $Str) (local.get $a))))
    (local.set $bb (struct.get $Str 0 (ref.cast (ref $Str) (local.get $b))))
    (local.set $lenA (array.len (local.get $ba)))
    (local.set $dest (array.new $Bytes (i32.const 0)
      (i32.add (local.get $lenA) (array.len (local.get $bb)))))
    (array.copy $Bytes $Bytes (local.get $dest) (i32.const 0) (local.get $ba) (i32.const 0) (local.get $lenA))
    (array.copy $Bytes $Bytes (local.get $dest) (local.get $lenA) (local.get $bb) (i32.const 0) (array.len (local.get $bb)))
    (struct.new $Str (local.get $dest)))

  ;; $rt.arrayConcat(a, b) -> eqref (Data.Semigroup `<>` on Array). Like strConcat,
  ;; but the elements are eqref and the $Vals array is itself the value (no struct).
  (func $rt.arrayConcat (export "arrayConcat") (param $a eqref) (param $b eqref) (result eqref)
    (local $va (ref $Vals))
    (local $vb (ref $Vals))
    (local $lenA i32)
    (local $dest (ref $Vals))
    (local.set $va (ref.cast (ref $Vals) (local.get $a)))
    (local.set $vb (ref.cast (ref $Vals) (local.get $b)))
    (local.set $lenA (array.len (local.get $va)))
    ;; init with a null eqref; every slot is overwritten by the copies below.
    (local.set $dest (array.new $Vals (ref.null none)
      (i32.add (local.get $lenA) (array.len (local.get $vb)))))
    (array.copy $Vals $Vals (local.get $dest) (i32.const 0) (local.get $va) (i32.const 0) (local.get $lenA))
    (array.copy $Vals $Vals (local.get $dest) (local.get $lenA) (local.get $vb) (i32.const 0) (array.len (local.get $vb)))
    (local.get $dest))

  ;; Apply a single-argument closure: f(x).
  ;; Apply an arity-1 closure to one argument (also exported as `applyClo` so the FFI
  ;; glue can call a PureScript closure passed to a JS foreign — ADR 0014 wasm→JS).
  (func $callClo1 (export "applyClo") (param $f eqref) (param $x eqref) (result eqref)
    (local $c (ref $Clo))
    (local.set $c (ref.cast (ref $Clo) (local.get $f)))
    (call_ref $Code (local.get $c) (local.get $x) (ref.cast (ref $Code) (struct.get $Clo 0 (local.get $c)))))

  ;; Effect.Ref / Control.Monad.ST native cell (ADR 0017). A `Ref` is a one-field
  ;; mutable `$Ref` struct holding the boxed value; the operations are wasm-native, so
  ;; nothing crosses to JS (the JS-origin-opaque limitation in docs/interop.md). The
  ;; `Effect` perform-unit is handled at the call site (the unit operand is dropped),
  ;; so these helpers are plain value functions.
  (func $rt.refNew (export "refNew") (param $v eqref) (result eqref)
    (struct.new $Ref (local.get $v)))
  (func $rt.refRead (export "refRead") (param $r eqref) (result eqref)
    (struct.get $Ref 0 (ref.cast (ref $Ref) (local.get $r))))
  ;; write returns Unit, encoded as the i32 `0` (matching the other Unit-result ops).
  (func $rt.refWrite (export "refWrite") (param $r eqref) (param $v eqref) (result i32)
    (struct.set $Ref 0 (ref.cast (ref $Ref) (local.get $r)) (local.get $v))
    (i32.const 0))
  ;; newWithSelf: the cell must exist before `f` runs (knot-tying), so allocate it with
  ;; a null placeholder, apply `f` to the (self) ref, then fill it in.
  (func $rt.refNewWithSelf (export "refNewWithSelf") (param $f eqref) (result eqref)
    (local $r (ref $Ref))
    (local.set $r (struct.new $Ref (ref.null none)))
    (struct.set $Ref 0 (local.get $r) (call $callClo1 (local.get $f) (local.get $r)))
    (local.get $r))
  ;; modifyImpl f r: apply `f` to the current value to get a `{ state, value }` record,
  ;; store `state` back, return `value`. The label ids are resolved by the caller (via
  ;; `internLabel`, the same ids the record's fields use) and passed in.
  (func $rt.refModify (export "refModify") (param $r eqref) (param $f eqref) (param $stateId i32) (param $valueId i32) (result eqref)
    (local $rec eqref)
    (local.set $rec (call $callClo1 (local.get $f)
                      (struct.get $Ref 0 (ref.cast (ref $Ref) (local.get $r)))))
    (struct.set $Ref 0 (ref.cast (ref $Ref) (local.get $r))
      (call $rt.proj (local.get $rec) (local.get $stateId)))
    (call $rt.proj (local.get $rec) (local.get $valueId)))

  ;; `effect` package control-flow primitives (ADR 0018). Each is a wasm loop that applies
  ;; the body/condition closure with the trampoline `$callClo1`. An `Effect a` argument is a
  ;; thunk ($Clo); *performing* it is `$callClo1(thunk, unit)` (the unit is ignored by the
  ;; thunk, so any eqref serves — an i31 0). All return Unit as the i32 0.
  (func $rt.forE (export "forE") (param $lo i32) (param $hi i32) (param $f eqref) (result i32)
    (local $i i32)
    (local.set $i (local.get $lo))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $hi)))
        (drop (call $callClo1
          (call $callClo1 (local.get $f) (call $boxInt (local.get $i)))
          (ref.i31 (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (i32.const 0))
  (func $rt.foreachE (export "foreachE") (param $arr eqref) (param $f eqref) (result i32)
    (local $i i32) (local $n i32)
    (local.set $n (call $arrayLen (local.get $arr)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (drop (call $callClo1
          (call $callClo1 (local.get $f) (call $arrayGet (local.get $arr) (local.get $i)))
          (ref.i31 (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (i32.const 0))
  (func $rt.whileE (export "whileE") (param $cond eqref) (param $body eqref) (result i32)
    (block $done
      (loop $loop
        (br_if $done (i32.eqz (call $unboxBool (call $callClo1 (local.get $cond) (ref.i31 (i32.const 0))))))
        (drop (call $callClo1 (local.get $body) (ref.i31 (i32.const 0))))
        (br $loop)))
    (i32.const 0))
  (func $rt.untilE (export "untilE") (param $act eqref) (result i32)
    (block $done
      (loop $loop
        (br_if $done (call $unboxBool (call $callClo1 (local.get $act) (ref.i31 (i32.const 0)))))
        (br $loop)))
    (i32.const 0))

  ;; $rt.arrayMap(f, xs) -> eqref (Data.Functor's arrayMap): map `f` over the array.
  (func $rt.arrayMap (export "arrayMap") (param $f eqref) (param $xs eqref) (result eqref)
    (local $va (ref $Vals))
    (local $n i32)
    (local $i i32)
    (local $out (ref $Vals))
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $va)))
    (local.set $out (array.new $Vals (ref.null none) (local.get $n)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (array.set $Vals (local.get $out) (local.get $i)
          (call $callClo1 (local.get $f) (array.get $Vals (local.get $va) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $out))

  ;; $rt.arrayApply(fs, xs) -> eqref (Control.Apply's arrayApply): every function in
  ;; `fs` applied to every element of `xs`, in `fs`-major order (length l*k).
  (func $rt.arrayApply (export "arrayApply") (param $fs eqref) (param $xs eqref) (result eqref)
    (local $vf (ref $Vals))
    (local $vx (ref $Vals))
    (local $l i32)
    (local $k i32)
    (local $i i32)
    (local $j i32)
    (local $n i32)
    (local $f eqref)
    (local $out (ref $Vals))
    (local.set $vf (ref.cast (ref $Vals) (local.get $fs)))
    (local.set $vx (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $l (array.len (local.get $vf)))
    (local.set $k (array.len (local.get $vx)))
    (local.set $out (array.new $Vals (ref.null none) (i32.mul (local.get $l) (local.get $k))))
    (block $di
      (loop $li
        (br_if $di (i32.ge_u (local.get $i) (local.get $l)))
        (local.set $f (array.get $Vals (local.get $vf) (local.get $i)))
        (local.set $j (i32.const 0))
        (block $dj
          (loop $lj
            (br_if $dj (i32.ge_u (local.get $j) (local.get $k)))
            (array.set $Vals (local.get $out) (local.get $n)
              (call $callClo1 (local.get $f) (array.get $Vals (local.get $vx) (local.get $j))))
            (local.set $n (i32.add (local.get $n) (i32.const 1)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lj)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $li)))
    (local.get $out))

  ;; $rt.arrayBind(xs, f) -> eqref (Control.Bind's arrayBind): flatMap. Two passes —
  ;; first apply `f` to each element (storing the sub-arrays and summing lengths),
  ;; then copy them into one result.
  (func $rt.arrayBind (export "arrayBind") (param $xs eqref) (param $f eqref) (result eqref)
    (local $vx (ref $Vals))
    (local $n i32)
    (local $results (ref $Vals))
    (local $i i32)
    (local $total i32)
    (local $sub (ref $Vals))
    (local $slen i32)
    (local $out (ref $Vals))
    (local $o i32)
    (local.set $vx (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $vx)))
    (local.set $results (array.new $Vals (ref.null none) (local.get $n)))
    (block $d1
      (loop $l1
        (br_if $d1 (i32.ge_u (local.get $i) (local.get $n)))
        (array.set $Vals (local.get $results) (local.get $i)
          (call $callClo1 (local.get $f) (array.get $Vals (local.get $vx) (local.get $i))))
        (local.set $total (i32.add (local.get $total)
          (array.len (ref.cast (ref $Vals) (array.get $Vals (local.get $results) (local.get $i))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l1)))
    (local.set $out (array.new $Vals (ref.null none) (local.get $total)))
    (local.set $i (i32.const 0))
    (block $d2
      (loop $l2
        (br_if $d2 (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $sub (ref.cast (ref $Vals) (array.get $Vals (local.get $results) (local.get $i))))
        (local.set $slen (array.len (local.get $sub)))
        (array.copy $Vals $Vals (local.get $out) (local.get $o) (local.get $sub) (i32.const 0) (local.get $slen))
        (local.set $o (i32.add (local.get $o) (local.get $slen)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l2)))
    (local.get $out))

  ;; Apply a curried two-argument closure: f(x)(y). `f` is an arity-1 $Clo whose
  ;; result is itself an arity-1 $Clo (PureScript curries), so two call_ref steps.
  (func $callClo2 (param $f eqref) (param $x eqref) (param $y eqref) (result eqref)
    (local $c1 (ref $Clo))
    (local $c2 (ref $Clo))
    (local.set $c1 (ref.cast (ref $Clo) (local.get $f)))
    (local.set $c2 (ref.cast (ref $Clo)
      (call_ref $Code (local.get $c1) (local.get $x) (ref.cast (ref $Code) (struct.get $Clo 0 (local.get $c1))))))
    (call_ref $Code (local.get $c2) (local.get $y) (ref.cast (ref $Code) (struct.get $Clo 0 (local.get $c2)))))

  ;; $rt.arrayEq(f, xs, ys) -> i32 (Data.Eq's eqArrayImpl): unequal lengths are not
  ;; equal; otherwise every element pair must satisfy the element-eq closure `f`.
  (func $rt.arrayEq (export "arrayEq") (param $f eqref) (param $xs eqref) (param $ys eqref) (result i32)
    (local $va (ref $Vals))
    (local $vb (ref $Vals))
    (local $n i32)
    (local $i i32)
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $vb (ref.cast (ref $Vals) (local.get $ys)))
    (local.set $n (array.len (local.get $va)))
    (if (i32.ne (local.get $n) (array.len (local.get $vb))) (then (return (i32.const 0))))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.eqz (i31.get_s (ref.cast i31ref
              (call $callClo2 (local.get $f)
                (array.get $Vals (local.get $va) (local.get $i))
                (array.get $Vals (local.get $vb) (local.get $i))))))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (i32.const 1))

  ;; $rt.arrayOrd(f, xs, ys) -> i32 (Data.Ord's ordArrayImpl): the first non-zero
  ;; element delta from `f` (a boxed Int), else the length comparison (the caller
  ;; maps this i32 back to an Ordering via `compare 0`).
  (func $rt.arrayOrd (export "arrayOrd") (param $f eqref) (param $xs eqref) (param $ys eqref) (result i32)
    (local $va (ref $Vals))
    (local $vb (ref $Vals))
    (local $la i32)
    (local $lb i32)
    (local $i i32)
    (local $o i32)
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $vb (ref.cast (ref $Vals) (local.get $ys)))
    (local.set $la (array.len (local.get $va)))
    (local.set $lb (array.len (local.get $vb)))
    (block $done (result i32)
      (loop $loop
        (if (i32.or (i32.ge_u (local.get $i) (local.get $la)) (i32.ge_u (local.get $i) (local.get $lb)))
          (then (br $done
            (if (result i32) (i32.eq (local.get $la) (local.get $lb)) (then (i32.const 0))
              (else (if (result i32) (i32.gt_u (local.get $la) (local.get $lb)) (then (i32.const -1)) (else (i32.const 1))))))))
        (local.set $o (struct.get $Int 0 (ref.cast (ref $Int)
          (call $callClo2 (local.get $f)
            (array.get $Vals (local.get $va) (local.get $i))
            (array.get $Vals (local.get $vb) (local.get $i))))))
        (if (i32.ne (local.get $o) (i32.const 0)) (then (br $done (local.get $o))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop))))

  ;; $rt.showInt(n) -> eqref ($Str) (Data.Show's showIntImpl): write the base-10
  ;; digits of `n` into an 11-byte scratch from the right, then copy the used suffix
  ;; into the result string. Digits are extracted from `n` in place via rem_s/div_s
  ;; (abs of each single-digit remainder), so INT_MIN is never negated as a whole.
  (func $rt.showInt (export "showInt") (param $n i32) (result eqref)
    (local $pos i32)
    (local $scratch (ref $Bytes))
    (local $neg i32)
    (local $len i32)
    (local $res (ref $Bytes))
    (local.set $neg (i32.lt_s (local.get $n) (i32.const 0)))
    (local.set $scratch (array.new $Bytes (i32.const 0) (i32.const 11)))
    (local.set $pos (i32.const 11))
    (loop $show
      (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
      (array.set $Bytes (local.get $scratch) (local.get $pos)
        (i32.add (i32.const 48)
          (if (result i32) (i32.lt_s (i32.rem_s (local.get $n) (i32.const 10)) (i32.const 0))
            (then (i32.sub (i32.const 0) (i32.rem_s (local.get $n) (i32.const 10))))
            (else (i32.rem_s (local.get $n) (i32.const 10))))))
      (local.set $n (i32.div_s (local.get $n) (i32.const 10)))
      (br_if $show (i32.ne (local.get $n) (i32.const 0))))
    (if (local.get $neg)
      (then
        (local.set $pos (i32.sub (local.get $pos) (i32.const 1)))
        (array.set $Bytes (local.get $scratch) (local.get $pos) (i32.const 45))))
    (local.set $len (i32.sub (i32.const 11) (local.get $pos)))
    (local.set $res (array.new $Bytes (i32.const 0) (local.get $len)))
    (array.copy $Bytes $Bytes (local.get $res) (i32.const 0) (local.get $scratch) (local.get $pos) (local.get $len))
    (struct.new $Str (local.get $res)))

  ;; Euclidean Int division (Data.EuclideanRing): a non-negative remainder and a
  ;; zero guard, which raw i32.rem_s/div_s (truncating, trapping on /0) lack.
  ;; intMod x y = ((x % |y|) + |y|) % |y|  (0 when y = 0)
  (func $rt.intMod (export "intMod") (param $x i32) (param $y i32) (result i32)
    (local $yy i32)
    (if (result i32) (i32.eqz (local.get $y))
      (then (i32.const 0))
      (else
        (local.set $yy
          (if (result i32) (i32.lt_s (local.get $y) (i32.const 0))
            (then (i32.sub (i32.const 0) (local.get $y)))
            (else (local.get $y))))
        (i32.rem_s
          (i32.add (i32.rem_s (local.get $x) (local.get $yy)) (local.get $yy))
          (local.get $yy)))))

  ;; intDiv x y = (x - intMod x y) / y  (exact; 0 when y = 0)
  (func $rt.intDiv (export "intDiv") (param $x i32) (param $y i32) (result i32)
    (if (result i32) (i32.eqz (local.get $y))
      (then (i32.const 0))
      (else
        (i32.div_s
          (i32.sub (local.get $x) (call $rt.intMod (local.get $x) (local.get $y)))
          (local.get $y)))))

  ;; intDegree x = min |x| maxInt  (maxInt only matters for INT_MIN, whose negation
  ;; overflows back to INT_MIN).
  (func $rt.intDegree (export "intDegree") (param $x i32) (result i32)
    (local $a i32)
    (local.set $a
      (if (result i32) (i32.lt_s (local.get $x) (i32.const 0))
        (then (i32.sub (i32.const 0) (local.get $x)))
        (else (local.get $x))))
    (if (result i32) (i32.lt_s (local.get $a) (i32.const 0))
      (then (i32.const 2147483647))
      (else (local.get $a))))

  ;; ---- Data.Show: Char / String rendering (internal helpers + the two foreigns) ----

  ;; arr[o] = b ; returns o + 1 (a compact byte append).
  (func $putByte (param $arr (ref $Bytes)) (param $o i32) (param $b i32) (result i32)
    (array.set $Bytes (local.get $arr) (local.get $o) (local.get $b))
    (i32.add (local.get $o) (i32.const 1)))

  ;; append the decimal digits of `b` (0..127) ; returns the new offset.
  (func $putDec (param $arr (ref $Bytes)) (param $o i32) (param $b i32) (result i32)
    (if (result i32) (i32.ge_u (local.get $b) (i32.const 100))
      (then
        (local.set $o (call $putByte (local.get $arr) (local.get $o)
          (i32.add (i32.const 48) (i32.div_u (local.get $b) (i32.const 100)))))
        (local.set $o (call $putByte (local.get $arr) (local.get $o)
          (i32.add (i32.const 48) (i32.rem_u (i32.div_u (local.get $b) (i32.const 10)) (i32.const 10)))))
        (call $putByte (local.get $arr) (local.get $o)
          (i32.add (i32.const 48) (i32.rem_u (local.get $b) (i32.const 10)))))
      (else
        (if (result i32) (i32.ge_u (local.get $b) (i32.const 10))
          (then
            (local.set $o (call $putByte (local.get $arr) (local.get $o)
              (i32.add (i32.const 48) (i32.div_u (local.get $b) (i32.const 10)))))
            (call $putByte (local.get $arr) (local.get $o)
              (i32.add (i32.const 48) (i32.rem_u (local.get $b) (i32.const 10)))))
          (else
            (call $putByte (local.get $arr) (local.get $o)
              (i32.add (i32.const 48) (local.get $b))))))))

  ;; the escape letter for a "named" control byte (\a \b \t \n \v \f \r), else 0.
  (func $namedEsc (param $b i32) (result i32)
    (if (result i32) (i32.eq (local.get $b) (i32.const 7)) (then (i32.const 97))
    (else (if (result i32) (i32.eq (local.get $b) (i32.const 8)) (then (i32.const 98))
    (else (if (result i32) (i32.eq (local.get $b) (i32.const 9)) (then (i32.const 116))
    (else (if (result i32) (i32.eq (local.get $b) (i32.const 10)) (then (i32.const 110))
    (else (if (result i32) (i32.eq (local.get $b) (i32.const 11)) (then (i32.const 118))
    (else (if (result i32) (i32.eq (local.get $b) (i32.const 12)) (then (i32.const 102))
    (else (if (result i32) (i32.eq (local.get $b) (i32.const 13)) (then (i32.const 114))
    (else (i32.const 0))))))))))))))))

  ;; append the UTF-8 encoding of code point `cp` (0..0xFFFF) ; returns new offset.
  (func $putUtf8 (param $arr (ref $Bytes)) (param $o i32) (param $cp i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x80))
      (then (call $putByte (local.get $arr) (local.get $o) (local.get $cp)))
      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x800))
        (then
          (local.set $o (call $putByte (local.get $arr) (local.get $o)
            (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6)))))
          (call $putByte (local.get $arr) (local.get $o)
            (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F)))))
        (else
          (local.set $o (call $putByte (local.get $arr) (local.get $o)
            (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12)))))
          (local.set $o (call $putByte (local.get $arr) (local.get $o)
            (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F)))))
          (call $putByte (local.get $arr) (local.get $o)
            (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F)))))))))

  ;; $rt.showChar(code) -> $Str (showCharImpl): quote with ', escaping control chars
  ;; (named \a.. or \DDD), ' and \, and UTF-8-encoding any other code point.
  (func $rt.showChar (export "showChar") (param $cp i32) (result eqref)
    (local $scratch (ref $Bytes))
    (local $o i32)
    (local $nb i32)
    (local $res (ref $Bytes))
    (local.set $scratch (array.new $Bytes (i32.const 0) (i32.const 8)))
    (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 39)))
    (if (i32.or (i32.lt_u (local.get $cp) (i32.const 0x20)) (i32.eq (local.get $cp) (i32.const 0x7F)))
      (then
        (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 92)))
        (local.set $nb (call $namedEsc (local.get $cp)))
        (if (local.get $nb)
          (then (local.set $o (call $putByte (local.get $scratch) (local.get $o) (local.get $nb))))
          (else (local.set $o (call $putDec (local.get $scratch) (local.get $o) (local.get $cp))))))
      (else
        (if (i32.or (i32.eq (local.get $cp) (i32.const 39)) (i32.eq (local.get $cp) (i32.const 92)))
          (then
            (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 92)))
            (local.set $o (call $putByte (local.get $scratch) (local.get $o) (local.get $cp))))
          (else
            (local.set $o (call $putUtf8 (local.get $scratch) (local.get $o) (local.get $cp)))))))
    (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 39)))
    (local.set $res (array.new $Bytes (i32.const 0) (local.get $o)))
    (array.copy $Bytes $Bytes (local.get $res) (i32.const 0) (local.get $scratch) (i32.const 0) (local.get $o))
    (struct.new $Str (local.get $res)))

  ;; $rt.showString(s) -> $Str (showStringImpl): quote with ", escaping ", \, named
  ;; control chars, and other controls as \DDD (+ \& when an ASCII digit follows, so
  ;; the decimal escape does not merge with it). Operates byte-by-byte on the UTF-8
  ;; bytes — every escaped byte is < 0x80, so multi-byte sequences pass through.
  (func $rt.showString (export "showString") (param $s eqref) (result eqref)
    (local $in (ref $Bytes))
    (local $n i32)
    (local $scratch (ref $Bytes))
    (local $o i32)
    (local $i i32)
    (local $b i32)
    (local $nb i32)
    (local $res (ref $Bytes))
    (local.set $in (struct.get $Str 0 (ref.cast (ref $Str) (local.get $s))))
    (local.set $n (array.len (local.get $in)))
    ;; worst case per byte is 6 (\DDD\&); plus the two surrounding quotes
    (local.set $scratch (array.new $Bytes (i32.const 0)
      (i32.add (i32.mul (local.get $n) (i32.const 6)) (i32.const 2))))
    (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 34)))
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $b (array.get $Bytes (local.get $in) (local.get $i)))
        (if (i32.or (i32.eq (local.get $b) (i32.const 34)) (i32.eq (local.get $b) (i32.const 92)))
          (then
            (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 92)))
            (local.set $o (call $putByte (local.get $scratch) (local.get $o) (local.get $b))))
          (else
            (local.set $nb (call $namedEsc (local.get $b)))
            (if (local.get $nb)
              (then
                (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 92)))
                (local.set $o (call $putByte (local.get $scratch) (local.get $o) (local.get $nb))))
              (else
                (if (i32.or (i32.lt_u (local.get $b) (i32.const 0x20)) (i32.eq (local.get $b) (i32.const 0x7F)))
                  (then
                    (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 92)))
                    (local.set $o (call $putDec (local.get $scratch) (local.get $o) (local.get $b)))
                    (if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $n))
                      (then
                        (local.set $nb (array.get $Bytes (local.get $in) (i32.add (local.get $i) (i32.const 1))))
                        (if (i32.and (i32.ge_u (local.get $nb) (i32.const 48)) (i32.le_u (local.get $nb) (i32.const 57)))
                          (then
                            (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 92)))
                            (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 38))))))))
                  (else
                    (local.set $o (call $putByte (local.get $scratch) (local.get $o) (local.get $b)))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.set $o (call $putByte (local.get $scratch) (local.get $o) (i32.const 34)))
    (local.set $res (array.new $Bytes (i32.const 0) (local.get $o)))
    (array.copy $Bytes $Bytes (local.get $res) (i32.const 0) (local.get $scratch) (i32.const 0) (local.get $o))
    (struct.new $Str (local.get $res)))

  ;; $rt.showArray(f, xs) -> $Str (showArrayImpl): render `[` + each element shown by
  ;; the closure `f` joined with `,` + `]`. `f` (a `$Clo`) is called per element via
  ;; call_ref; the rendered `$Str`s are stored so the closure runs once each, then
  ;; their bytes are measured and copied into the result.
  (func $rt.showArray (export "showArray") (param $f eqref) (param $xs eqref) (result eqref)
    (local $clo (ref $Clo))
    (local $arr (ref $Vals))
    (local $n i32)
    (local $results (ref $Vals))
    (local $i i32)
    (local $total i32)
    (local $s (ref $Bytes))
    (local $out (ref $Bytes))
    (local $o i32)
    (local.set $clo (ref.cast (ref $Clo) (local.get $f)))
    (local.set $arr (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $arr)))
    (local.set $results (array.new $Vals (ref.null none) (local.get $n)))
    (local.set $total (i32.const 2)) ;; the surrounding [ and ]
    ;; render each element once, store its $Str, and sum the byte lengths + commas
    (block $end1
      (loop $loop1
        (br_if $end1 (i32.ge_u (local.get $i) (local.get $n)))
        (array.set $Vals (local.get $results) (local.get $i)
          (call_ref $Code
            (local.get $clo)
            (array.get $Vals (local.get $arr) (local.get $i))
            (ref.cast (ref $Code) (struct.get $Clo 0 (local.get $clo)))))
        (if (i32.gt_u (local.get $i) (i32.const 0))
          (then (local.set $total (i32.add (local.get $total) (i32.const 1)))))
        (local.set $total (i32.add (local.get $total)
          (array.len (struct.get $Str 0
            (ref.cast (ref $Str) (array.get $Vals (local.get $results) (local.get $i)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop1)))
    ;; build [ s0 , s1 , … ]
    (local.set $out (array.new $Bytes (i32.const 0) (local.get $total)))
    (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 91)))
    (local.set $i (i32.const 0))
    (block $end2
      (loop $loop2
        (br_if $end2 (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.gt_u (local.get $i) (i32.const 0))
          (then (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 44)))))
        (local.set $s (struct.get $Str 0
          (ref.cast (ref $Str) (array.get $Vals (local.get $results) (local.get $i)))))
        (array.copy $Bytes $Bytes (local.get $out) (local.get $o) (local.get $s) (i32.const 0) (array.len (local.get $s)))
        (local.set $o (i32.add (local.get $o) (array.len (local.get $s))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop2)))
    (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 93)))
    (struct.new $Str (local.get $out)))

  ;; $rt.intercalate(sep, xs) -> $Str (Data.Show.Generic's `intercalate` foreign):
  ;; join the already-rendered $Str elements of array `xs` (a $Vals) with the $Str
  ;; separator `sep`. Two passes like showArray: sum the byte lengths, then copy.
  (func $rt.intercalate (export "intercalate") (param $sep eqref) (param $xs eqref) (result eqref)
    (local $arr (ref $Vals))
    (local $sepb (ref $Bytes))
    (local $n i32)
    (local $i i32)
    (local $total i32)
    (local $s (ref $Bytes))
    (local $out (ref $Bytes))
    (local $o i32)
    (local.set $arr (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $sepb (struct.get $Str 0 (ref.cast (ref $Str) (local.get $sep))))
    (local.set $n (array.len (local.get $arr)))
    ;; total = sum element bytes + (n-1) separators (no separator before the first)
    (block $end1
      (loop $loop1
        (br_if $end1 (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.gt_u (local.get $i) (i32.const 0))
          (then (local.set $total (i32.add (local.get $total) (array.len (local.get $sepb))))))
        (local.set $total (i32.add (local.get $total)
          (array.len (struct.get $Str 0
            (ref.cast (ref $Str) (array.get $Vals (local.get $arr) (local.get $i)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop1)))
    (local.set $out (array.new $Bytes (i32.const 0) (local.get $total)))
    (local.set $i (i32.const 0))
    (block $end2
      (loop $loop2
        (br_if $end2 (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.gt_u (local.get $i) (i32.const 0))
          (then
            (array.copy $Bytes $Bytes (local.get $out) (local.get $o) (local.get $sepb) (i32.const 0) (array.len (local.get $sepb)))
            (local.set $o (i32.add (local.get $o) (array.len (local.get $sepb))))))
        (local.set $s (struct.get $Str 0
          (ref.cast (ref $Str) (array.get $Vals (local.get $arr) (local.get $i)))))
        (array.copy $Bytes $Bytes (local.get $out) (local.get $o) (local.get $s) (i32.const 0) (array.len (local.get $s)))
        (local.set $o (i32.add (local.get $o) (array.len (local.get $s))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop2)))
    (struct.new $Str (local.get $out)))

  ;; ---- Data.Show: Number (showNumberImpl) ----
  ;; Shortest round-trip f64 -> decimal via Dragon4 (Steele-White / Burger-Dybvig):
  ;; a fixed-capacity big-integer (64 i32 limbs, base 2^32, little-endian, stored in
  ;; the same (array (mut i32)) as $Bytes) drives an exact scaled-value digit loop, so
  ;; no power-of-ten tables are needed (unlike Ryu). The digits + decimal point then
  ;; go through the ECMAScript Number::toString formatting rules.

  (func $bnNew (result (ref $Bytes)) (array.new $Bytes (i32.const 0) (i32.const 64)))

  (func $bnSetU64 (param $a (ref $Bytes)) (param $v i64)
    (array.set $Bytes (local.get $a) (i32.const 0) (i32.wrap_i64 (local.get $v)))
    (array.set $Bytes (local.get $a) (i32.const 1) (i32.wrap_i64 (i64.shr_u (local.get $v) (i64.const 32)))))

  (func $bnCopy (param $dst (ref $Bytes)) (param $src (ref $Bytes))
    (array.copy $Bytes $Bytes (local.get $dst) (i32.const 0) (local.get $src) (i32.const 0) (i32.const 64)))

  ;; compare unsigned, from the most-significant limb down: -1 / 0 / 1.
  (func $bnCmp (param $a (ref $Bytes)) (param $b (ref $Bytes)) (result i32)
    (local $i i32) (local $av i32) (local $bv i32)
    (local.set $i (i32.const 63))
    (block $done (result i32)
      (loop $loop
        (local.set $av (array.get $Bytes (local.get $a) (local.get $i)))
        (local.set $bv (array.get $Bytes (local.get $b) (local.get $i)))
        (if (i32.ne (local.get $av) (local.get $bv))
          (then (br $done (if (result i32) (i32.lt_u (local.get $av) (local.get $bv)) (then (i32.const -1)) (else (i32.const 1))))))
        (if (i32.eqz (local.get $i)) (then (br $done (i32.const 0))))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br $loop))))

  ;; a *= mul  (mul small, e.g. 2 / 4 / 10)
  (func $bnMulSmall (param $a (ref $Bytes)) (param $mul i32)
    (local $i i32) (local $carry i64) (local $p i64)
    (loop $loop
      (local.set $p (i64.add
        (i64.mul (i64.extend_i32_u (array.get $Bytes (local.get $a) (local.get $i))) (i64.extend_i32_u (local.get $mul)))
        (local.get $carry)))
      (array.set $Bytes (local.get $a) (local.get $i) (i32.wrap_i64 (local.get $p)))
      (local.set $carry (i64.shr_u (local.get $p) (i64.const 32)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop (i32.lt_u (local.get $i) (i32.const 64)))))

  ;; a += b
  (func $bnAdd (param $a (ref $Bytes)) (param $b (ref $Bytes))
    (local $i i32) (local $carry i64) (local $p i64)
    (loop $loop
      (local.set $p (i64.add (i64.add
        (i64.extend_i32_u (array.get $Bytes (local.get $a) (local.get $i)))
        (i64.extend_i32_u (array.get $Bytes (local.get $b) (local.get $i))))
        (local.get $carry)))
      (array.set $Bytes (local.get $a) (local.get $i) (i32.wrap_i64 (local.get $p)))
      (local.set $carry (i64.shr_u (local.get $p) (i64.const 32)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop (i32.lt_u (local.get $i) (i32.const 64)))))

  ;; a -= b  (requires a >= b)
  (func $bnSub (param $a (ref $Bytes)) (param $b (ref $Bytes))
    (local $i i32) (local $borrow i64) (local $d i64)
    (loop $loop
      (local.set $d (i64.sub (i64.sub
        (i64.extend_i32_u (array.get $Bytes (local.get $a) (local.get $i)))
        (i64.extend_i32_u (array.get $Bytes (local.get $b) (local.get $i))))
        (local.get $borrow)))
      (array.set $Bytes (local.get $a) (local.get $i) (i32.wrap_i64 (local.get $d)))
      (local.set $borrow (i64.and (i64.shr_u (local.get $d) (i64.const 63)) (i64.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop (i32.lt_u (local.get $i) (i32.const 64)))))

  ;; a *= 2, n times
  (func $bnMul2n (param $a (ref $Bytes)) (param $n i32)
    (block $done (loop $loop
      (br_if $done (i32.eqz (local.get $n)))
      (call $bnMulSmall (local.get $a) (i32.const 2))
      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
      (br $loop))))

  ;; a = 2^p
  (func $bnSetPow2 (param $a (ref $Bytes)) (param $p i32)
    (array.set $Bytes (local.get $a) (i32.const 0) (i32.const 1))
    (call $bnMul2n (local.get $a) (local.get $p)))

  (func $rt.showNumber (export "showNumber") (param $x f64) (result eqref)
    (local $bits i64)
    (local $sign i32)
    (local $ef i32)
    (local $frac i64)
    (local $m i64)
    (local $e i32)
    (local $boundary i32)
    (local $evenM i32)
    (local $R (ref $Bytes))
    (local $S (ref $Bytes))
    (local $mP (ref $Bytes))
    (local $mM (ref $Bytes))
    (local $tmp (ref $Bytes))
    (local $digits (ref $Bytes))
    (local $K i32)
    (local $pp i32)
    (local $d i32)
    (local $low i32)
    (local $high i32)
    (local $c i32)
    (local $ci i32)
    (local $out (ref $Bytes))
    (local $res (ref $Bytes))
    (local $o i32)
    (local $j i32)
    (local.set $bits (i64.reinterpret_f64 (local.get $x)))
    (local.set $sign (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 63)) (i64.const 1))))
    (local.set $ef (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52)) (i64.const 0x7FF))))
    (local.set $frac (i64.and (local.get $bits) (i64.const 0xFFFFFFFFFFFFF)))
    ;; Infinity / NaN
    (if (i32.eq (local.get $ef) (i32.const 0x7FF))
      (then
        (if (i64.eqz (local.get $frac))
          (then (return (if (result eqref) (local.get $sign)
            (then (struct.new $Str (array.new_fixed $Bytes 9 (i32.const 45) (i32.const 73) (i32.const 110) (i32.const 102) (i32.const 105) (i32.const 110) (i32.const 105) (i32.const 116) (i32.const 121))))
            (else (struct.new $Str (array.new_fixed $Bytes 8 (i32.const 73) (i32.const 110) (i32.const 102) (i32.const 105) (i32.const 110) (i32.const 105) (i32.const 116) (i32.const 121)))))))
          (else (return (struct.new $Str (array.new_fixed $Bytes 3 (i32.const 78) (i32.const 97) (i32.const 78))))))))
    ;; zero (and -0): "0.0"
    (if (i32.and (i32.eqz (local.get $ef)) (i64.eqz (local.get $frac)))
      (then (return (struct.new $Str (array.new_fixed $Bytes 3 (i32.const 48) (i32.const 46) (i32.const 48))))))
    ;; mantissa m and exponent e: value = m * 2^e
    (if (i32.eqz (local.get $ef))
      (then (local.set $m (local.get $frac)) (local.set $e (i32.const -1074)))
      (else
        (local.set $m (i64.or (local.get $frac) (i64.const 0x10000000000000)))
        (local.set $e (i32.sub (local.get $ef) (i32.const 1075)))))
    (local.set $evenM (i32.eqz (i32.and (i32.wrap_i64 (local.get $m)) (i32.const 1))))
    ;; boundary: a power of two (frac==0) above the smallest normal (ef>1) has a
    ;; half-size gap below, so the lower margin halves.
    (local.set $boundary (i32.and (i32.gt_u (local.get $ef) (i32.const 1)) (i64.eqz (local.get $frac))))
    (local.set $R (call $bnNew))
    (local.set $S (call $bnNew))
    (local.set $mP (call $bnNew))
    (local.set $mM (call $bnNew))
    (local.set $tmp (call $bnNew))
    (call $bnSetU64 (local.get $R) (local.get $m))
    (if (i32.ge_s (local.get $e) (i32.const 0))
      (then
        (if (local.get $boundary)
          (then
            (call $bnMul2n (local.get $R) (i32.add (local.get $e) (i32.const 2)))
            (array.set $Bytes (local.get $S) (i32.const 0) (i32.const 4))
            (call $bnSetPow2 (local.get $mP) (i32.add (local.get $e) (i32.const 1)))
            (call $bnSetPow2 (local.get $mM) (local.get $e)))
          (else
            (call $bnMul2n (local.get $R) (i32.add (local.get $e) (i32.const 1)))
            (array.set $Bytes (local.get $S) (i32.const 0) (i32.const 2))
            (call $bnSetPow2 (local.get $mP) (local.get $e))
            (call $bnSetPow2 (local.get $mM) (local.get $e)))))
      (else
        (if (local.get $boundary)
          (then
            (call $bnMul2n (local.get $R) (i32.const 2))
            (call $bnSetPow2 (local.get $S) (i32.sub (i32.const 2) (local.get $e)))
            (array.set $Bytes (local.get $mP) (i32.const 0) (i32.const 2))
            (array.set $Bytes (local.get $mM) (i32.const 0) (i32.const 1)))
          (else
            (call $bnMul2n (local.get $R) (i32.const 1))
            (call $bnSetPow2 (local.get $S) (i32.sub (i32.const 1) (local.get $e)))
            (array.set $Bytes (local.get $mP) (i32.const 0) (i32.const 1))
            (array.set $Bytes (local.get $mM) (i32.const 0) (i32.const 1))))))
    ;; scale: bring R/S into [0.1, 1), counting the decimal point position pp
    (local.set $pp (i32.const 0))
    (block $sc1 (loop $scl1
      (br_if $sc1 (i32.lt_s (call $bnCmp (local.get $R) (local.get $S)) (i32.const 0)))
      (call $bnMulSmall (local.get $S) (i32.const 10))
      (local.set $pp (i32.add (local.get $pp) (i32.const 1)))
      (br $scl1)))
    (block $sc2 (loop $scl2
      (call $bnCopy (local.get $tmp) (local.get $R))
      (call $bnMulSmall (local.get $tmp) (i32.const 10))
      (br_if $sc2 (i32.ge_s (call $bnCmp (local.get $tmp) (local.get $S)) (i32.const 0)))
      (call $bnMulSmall (local.get $R) (i32.const 10))
      (call $bnMulSmall (local.get $mP) (i32.const 10))
      (call $bnMulSmall (local.get $mM) (i32.const 10))
      (local.set $pp (i32.sub (local.get $pp) (i32.const 1)))
      (br $scl2)))
    ;; generate shortest digits
    (local.set $digits (call $bnNew))
    (local.set $K (i32.const 0))
    (block $dgend (loop $dg
      (call $bnMulSmall (local.get $R) (i32.const 10))
      (call $bnMulSmall (local.get $mP) (i32.const 10))
      (call $bnMulSmall (local.get $mM) (i32.const 10))
      (local.set $d (i32.const 0))
      (block $ddend (loop $ddl
        (br_if $ddend (i32.lt_s (call $bnCmp (local.get $R) (local.get $S)) (i32.const 0)))
        (call $bnSub (local.get $R) (local.get $S))
        (local.set $d (i32.add (local.get $d) (i32.const 1)))
        (br $ddl)))
      (local.set $c (call $bnCmp (local.get $R) (local.get $mM)))
      (local.set $low (if (result i32) (local.get $evenM)
        (then (i32.le_s (local.get $c) (i32.const 0)))
        (else (i32.lt_s (local.get $c) (i32.const 0)))))
      (call $bnCopy (local.get $tmp) (local.get $R))
      (call $bnAdd (local.get $tmp) (local.get $mP))
      (local.set $c (call $bnCmp (local.get $tmp) (local.get $S)))
      (local.set $high (if (result i32) (local.get $evenM)
        (then (i32.ge_s (local.get $c) (i32.const 0)))
        (else (i32.gt_s (local.get $c) (i32.const 0)))))
      (if (i32.and (i32.eqz (local.get $low)) (i32.eqz (local.get $high)))
        (then
          (array.set $Bytes (local.get $digits) (local.get $K) (local.get $d))
          (local.set $K (i32.add (local.get $K) (i32.const 1)))
          (br $dg)))
      ;; terminate: choose d or d+1
      (if (i32.and (local.get $low) (i32.eqz (local.get $high)))
        (then (array.set $Bytes (local.get $digits) (local.get $K) (local.get $d)))
        (else (if (i32.and (local.get $high) (i32.eqz (local.get $low)))
          (then (array.set $Bytes (local.get $digits) (local.get $K) (i32.add (local.get $d) (i32.const 1))))
          (else
            (call $bnCopy (local.get $tmp) (local.get $R))
            (call $bnMulSmall (local.get $tmp) (i32.const 2))
            (local.set $c (call $bnCmp (local.get $tmp) (local.get $S)))
            (if (i32.lt_s (local.get $c) (i32.const 0))
              (then (array.set $Bytes (local.get $digits) (local.get $K) (local.get $d)))
              (else (if (i32.gt_s (local.get $c) (i32.const 0))
                (then (array.set $Bytes (local.get $digits) (local.get $K) (i32.add (local.get $d) (i32.const 1))))
                (else (array.set $Bytes (local.get $digits) (local.get $K)
                  (i32.add (local.get $d) (i32.and (local.get $d) (i32.const 1))))))))))))
      (local.set $K (i32.add (local.get $K) (i32.const 1)))
      (br $dgend)))
    ;; carry if the last (rounded) digit became 10
    (local.set $ci (i32.sub (local.get $K) (i32.const 1)))
    (block $cend (loop $cl
      (br_if $cend (i32.ne (array.get $Bytes (local.get $digits) (local.get $ci)) (i32.const 10)))
      (array.set $Bytes (local.get $digits) (local.get $ci) (i32.const 0))
      (if (i32.eqz (local.get $ci))
        (then
          (array.set $Bytes (local.get $digits) (i32.const 0) (i32.const 1))
          (local.set $K (i32.const 1))
          (local.set $pp (i32.add (local.get $pp) (i32.const 1)))
          (br $cend))
        (else
          (local.set $ci (i32.sub (local.get $ci) (i32.const 1)))
          (array.set $Bytes (local.get $digits) (local.get $ci)
            (i32.add (array.get $Bytes (local.get $digits) (local.get $ci)) (i32.const 1)))
          (br $cl)))))
    ;; strip trailing zeros (keep at least one digit)
    (block $strz (loop $strl
      (br_if $strz (i32.le_s (local.get $K) (i32.const 1)))
      (br_if $strz (i32.ne (array.get $Bytes (local.get $digits) (i32.sub (local.get $K) (i32.const 1))) (i32.const 0)))
      (local.set $K (i32.sub (local.get $K) (i32.const 1)))
      (br $strl)))
    ;; ---- ECMAScript Number::toString formatting (n = pp, k = K) ----
    (local.set $out (array.new $Bytes (i32.const 0) (i32.const 40)))
    (local.set $o (i32.const 0))
    (if (local.get $sign)
      (then (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 45)))))
    (if (i32.and (i32.le_s (local.get $K) (local.get $pp)) (i32.le_s (local.get $pp) (i32.const 21)))
      (then ;; integer: digits, then (pp-K) zeros, then ".0"
        (local.set $j (i32.const 0))
        (block $f1 (loop $f1l (br_if $f1 (i32.ge_s (local.get $j) (local.get $K)))
          (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.add (i32.const 48) (array.get $Bytes (local.get $digits) (local.get $j)))))
          (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f1l)))
        (block $f1b (loop $f1bl (br_if $f1b (i32.ge_s (local.get $j) (local.get $pp)))
          (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 48)))
          (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f1bl)))
        (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 46)))
        (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 48))))
      (else (if (i32.and (i32.gt_s (local.get $pp) (i32.const 0)) (i32.le_s (local.get $pp) (i32.const 21)))
        (then ;; digits[0..pp] '.' digits[pp..K]
          (local.set $j (i32.const 0))
          (block $f2 (loop $f2l (br_if $f2 (i32.ge_s (local.get $j) (local.get $pp)))
            (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.add (i32.const 48) (array.get $Bytes (local.get $digits) (local.get $j)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f2l)))
          (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 46)))
          (block $f2b (loop $f2bl (br_if $f2b (i32.ge_s (local.get $j) (local.get $K)))
            (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.add (i32.const 48) (array.get $Bytes (local.get $digits) (local.get $j)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f2bl))))
        (else (if (i32.and (i32.le_s (local.get $pp) (i32.const 0)) (i32.gt_s (local.get $pp) (i32.const -6)))
          (then ;; "0." (-pp) zeros, digits
            (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 48)))
            (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 46)))
            (local.set $j (local.get $pp))
            (block $f3 (loop $f3l (br_if $f3 (i32.ge_s (local.get $j) (i32.const 0)))
              (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 48)))
              (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f3l)))
            (local.set $j (i32.const 0))
            (block $f3b (loop $f3bl (br_if $f3b (i32.ge_s (local.get $j) (local.get $K)))
              (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.add (i32.const 48) (array.get $Bytes (local.get $digits) (local.get $j)))))
              (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f3bl))))
          (else ;; exponential: d0 ('.' rest) 'e' sign exp
            (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.add (i32.const 48) (array.get $Bytes (local.get $digits) (i32.const 0)))))
            (if (i32.gt_s (local.get $K) (i32.const 1))
              (then
                (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 46)))
                (local.set $j (i32.const 1))
                (block $f4 (loop $f4l (br_if $f4 (i32.ge_s (local.get $j) (local.get $K)))
                  (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.add (i32.const 48) (array.get $Bytes (local.get $digits) (local.get $j)))))
                  (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $f4l)))))
            (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 101)))
            (if (i32.ge_s (i32.sub (local.get $pp) (i32.const 1)) (i32.const 0))
              (then
                (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 43)))
                (local.set $o (call $putDec (local.get $out) (local.get $o) (i32.sub (local.get $pp) (i32.const 1)))))
              (else
                (local.set $o (call $putByte (local.get $out) (local.get $o) (i32.const 45)))
                (local.set $o (call $putDec (local.get $out) (local.get $o) (i32.sub (i32.const 1) (local.get $pp))))))))))))
    (local.set $res (array.new $Bytes (i32.const 0) (local.get $o)))
    (array.copy $Bytes $Bytes (local.get $res) (i32.const 0) (local.get $out) (i32.const 0) (local.get $o))
    (struct.new $Str (local.get $res)))

  ;; ===== ulib batch 0: library FFIs the `examples/metatheory` front-end needs =========
  ;; Staged in the runtime so the program is self-contained (no JS marshalling of these
  ;; foreigns). ADR 0012 (ulib) will relocate these into curated per-package modules.

  ;; Data.Array.reverse
  (func $rt.arrayReverse (export "arrayReverse") (param $xs eqref) (result eqref)
    (local $va (ref $Vals))
    (local $n i32)
    (local $i i32)
    (local $out (ref $Vals))
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $va)))
    (local.set $out (array.new $Vals (ref.null none) (local.get $n)))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (array.set $Vals (local.get $out) (local.get $i)
          (array.get $Vals (local.get $va) (i32.sub (i32.sub (local.get $n) (i32.const 1)) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $out))

  ;; Data.Array.sliceImpl start end xs  (clamped, like JS Array.prototype.slice for 0<=s<=e<=n)
  (func $rt.arraySlice (export "arraySlice") (param $start i32) (param $end i32) (param $xs eqref) (result eqref)
    (local $va (ref $Vals))
    (local $n i32)
    (local $s i32)
    (local $e i32)
    (local $i i32)
    (local $out (ref $Vals))
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $va)))
    (local.set $s (local.get $start))
    (local.set $e (local.get $end))
    (if (i32.lt_s (local.get $s) (i32.const 0)) (then (local.set $s (i32.const 0))))
    (if (i32.gt_s (local.get $s) (local.get $n)) (then (local.set $s (local.get $n))))
    (if (i32.lt_s (local.get $e) (local.get $s)) (then (local.set $e (local.get $s))))
    (if (i32.gt_s (local.get $e) (local.get $n)) (then (local.set $e (local.get $n))))
    (local.set $out (array.new $Vals (ref.null none) (i32.sub (local.get $e) (local.get $s))))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.sub (local.get $e) (local.get $s))))
        (array.set $Vals (local.get $out) (local.get $i)
          (array.get $Vals (local.get $va) (i32.add (local.get $s) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $out))

  ;; Data.Array.indexImpl just nothing xs i  (safe index: `just xs[i]` in range else `nothing`)
  (func $rt.arrayIndexSafe (export "arrayIndexSafe") (param $just eqref) (param $nothing eqref) (param $xs eqref) (param $i i32) (result eqref)
    (local $va (ref $Vals))
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (if (result eqref)
      (i32.and (i32.ge_s (local.get $i) (i32.const 0)) (i32.lt_u (local.get $i) (array.len (local.get $va))))
      (then (call $callClo1 (local.get $just) (array.get $Vals (local.get $va) (local.get $i))))
      (else (local.get $nothing))))

  ;; Data.Array.unconsImpl empty next xs  (`empty unit` when null, else `next head tail`)
  (func $rt.arrayUncons (export "arrayUncons") (param $empty eqref) (param $next eqref) (param $xs eqref) (result eqref)
    (local $va (ref $Vals))
    (local $n i32)
    (local $i i32)
    (local $rest (ref $Vals))
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $va)))
    (if (result eqref) (i32.eqz (local.get $n))
      (then (call $callClo1 (local.get $empty) (ref.i31 (i32.const 0))))
      (else
        (local.set $rest (array.new $Vals (ref.null none) (i32.sub (local.get $n) (i32.const 1))))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.sub (local.get $n) (i32.const 1))))
            (array.set $Vals (local.get $rest) (local.get $i)
              (array.get $Vals (local.get $va) (i32.add (local.get $i) (i32.const 1))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)))
        (call $callClo1
          (call $callClo1 (local.get $next) (array.get $Vals (local.get $va) (i32.const 0)))
          (local.get $rest)))))

  ;; Data.Foldable.foldlArray f z xs
  (func $rt.foldlArray (export "foldlArray") (param $f eqref) (param $z eqref) (param $xs eqref) (result eqref)
    (local $va (ref $Vals))
    (local $n i32)
    (local $i i32)
    (local $acc eqref)
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $n (array.len (local.get $va)))
    (local.set $acc (local.get $z))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc
          (call $callClo1 (call $callClo1 (local.get $f) (local.get $acc)) (array.get $Vals (local.get $va) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $acc))

  ;; Data.Foldable.foldrArray f z xs
  (func $rt.foldrArray (export "foldrArray") (param $f eqref) (param $z eqref) (param $xs eqref) (result eqref)
    (local $va (ref $Vals))
    (local $i i32)
    (local $acc eqref)
    (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
    (local.set $acc (local.get $z))
    (local.set $i (array.len (local.get $va)))
    (block $done
      (loop $loop
        (br_if $done (i32.eqz (local.get $i)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (local.set $acc
          (call $callClo1 (call $callClo1 (local.get $f) (array.get $Vals (local.get $va) (local.get $i))) (local.get $acc)))
        (br $loop)))
    (local.get $acc))

  ;; ---- UTF-8 codec for Char (UTF-16 code unit) <-> $Str (UTF-8) -----------------------
  ;; byte length of the UTF-8 encoding of a code point
  (func $rt.utf8Len (param $cp i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x80)) (then (i32.const 1))
      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x800)) (then (i32.const 2))
        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x10000)) (then (i32.const 3))
          (else (i32.const 4))))))))

  ;; encode `cp` into `s` at byte offset `o`, returning the next offset
  (func $rt.utf8Encode (param $s eqref) (param $o i32) (param $cp i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x80))
      (then
        (call $strSetByte (local.get $s) (local.get $o) (local.get $cp))
        (i32.add (local.get $o) (i32.const 1)))
      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x800))
        (then
          (call $strSetByte (local.get $s) (local.get $o) (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
          (call $strSetByte (local.get $s) (i32.add (local.get $o) (i32.const 1)) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
          (i32.add (local.get $o) (i32.const 2)))
        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x10000))
          (then
            (call $strSetByte (local.get $s) (local.get $o) (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
            (call $strSetByte (local.get $s) (i32.add (local.get $o) (i32.const 1)) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
            (call $strSetByte (local.get $s) (i32.add (local.get $o) (i32.const 2)) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
            (i32.add (local.get $o) (i32.const 3)))
          (else
            (call $strSetByte (local.get $s) (local.get $o) (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
            (call $strSetByte (local.get $s) (i32.add (local.get $o) (i32.const 1)) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0x3F))))
            (call $strSetByte (local.get $s) (i32.add (local.get $o) (i32.const 2)) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
            (call $strSetByte (local.get $s) (i32.add (local.get $o) (i32.const 3)) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
            (i32.add (local.get $o) (i32.const 4)))))))))

  ;; Data.String.CodeUnits.singleton : a single UTF-16 code unit -> $Str
  (func $rt.charSingleton (export "charSingleton") (param $cp i32) (result eqref)
    (local $s eqref)
    (local.set $s (call $strNew (call $rt.utf8Len (local.get $cp))))
    (drop (call $rt.utf8Encode (local.get $s) (i32.const 0) (local.get $cp)))
    (local.get $s))

  ;; Data.String.CodeUnits.toCharArray : $Str (UTF-8) -> Array Char (UTF-16 code units)
  (func $rt.toCharArray (export "toCharArray") (param $str eqref) (result eqref)
    (local $n i32)
    (local $i i32)
    (local $units i32)
    (local $b i32)
    (local $cp i32)
    (local $len i32)
    (local $out (ref $Vals))
    (local $j i32)
    (local.set $n (call $strLen (local.get $str)))
    ;; pass 1: count code units (astral code points need a surrogate pair = 2 units)
    (block $d1
      (loop $l1
        (br_if $d1 (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $b (call $strByteAt (local.get $str) (local.get $i)))
        (local.set $len
          (if (result i32) (i32.lt_u (local.get $b) (i32.const 0x80)) (then (i32.const 1))
            (else (if (result i32) (i32.lt_u (local.get $b) (i32.const 0xE0)) (then (i32.const 2))
              (else (if (result i32) (i32.lt_u (local.get $b) (i32.const 0xF0)) (then (i32.const 3))
                (else (i32.const 4))))))))
        (local.set $units (i32.add (local.get $units)
          (if (result i32) (i32.eq (local.get $len) (i32.const 4)) (then (i32.const 2)) (else (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (local.get $len)))
        (br $l1)))
    (local.set $out (array.new $Vals (ref.null none) (local.get $units)))
    ;; pass 2: decode each sequence and write code unit(s)
    (local.set $i (i32.const 0))
    (block $d2
      (loop $l2
        (br_if $d2 (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $b (call $strByteAt (local.get $str) (local.get $i)))
        (if (i32.lt_u (local.get $b) (i32.const 0x80))
          (then (local.set $cp (local.get $b)) (local.set $len (i32.const 1)))
          (else (if (i32.lt_u (local.get $b) (i32.const 0xE0))
            (then
              (local.set $cp (i32.or
                (i32.shl (i32.and (local.get $b) (i32.const 0x1F)) (i32.const 6))
                (i32.and (call $strByteAt (local.get $str) (i32.add (local.get $i) (i32.const 1))) (i32.const 0x3F))))
              (local.set $len (i32.const 2)))
            (else (if (i32.lt_u (local.get $b) (i32.const 0xF0))
              (then
                (local.set $cp (i32.or (i32.or
                  (i32.shl (i32.and (local.get $b) (i32.const 0x0F)) (i32.const 12))
                  (i32.shl (i32.and (call $strByteAt (local.get $str) (i32.add (local.get $i) (i32.const 1))) (i32.const 0x3F)) (i32.const 6)))
                  (i32.and (call $strByteAt (local.get $str) (i32.add (local.get $i) (i32.const 2))) (i32.const 0x3F))))
                (local.set $len (i32.const 3)))
              (else
                (local.set $cp (i32.or (i32.or (i32.or
                  (i32.shl (i32.and (local.get $b) (i32.const 0x07)) (i32.const 18))
                  (i32.shl (i32.and (call $strByteAt (local.get $str) (i32.add (local.get $i) (i32.const 1))) (i32.const 0x3F)) (i32.const 12)))
                  (i32.shl (i32.and (call $strByteAt (local.get $str) (i32.add (local.get $i) (i32.const 2))) (i32.const 0x3F)) (i32.const 6)))
                  (i32.and (call $strByteAt (local.get $str) (i32.add (local.get $i) (i32.const 3))) (i32.const 0x3F))))
                (local.set $len (i32.const 4))))))))
        (if (i32.le_u (local.get $cp) (i32.const 0xFFFF))
          (then
            (array.set $Vals (local.get $out) (local.get $j) (call $boxInt (local.get $cp)))
            (local.set $j (i32.add (local.get $j) (i32.const 1))))
          (else
            (local.set $cp (i32.sub (local.get $cp) (i32.const 0x10000)))
            (array.set $Vals (local.get $out) (local.get $j)
              (call $boxInt (i32.or (i32.const 0xD800) (i32.shr_u (local.get $cp) (i32.const 10)))))
            (array.set $Vals (local.get $out) (i32.add (local.get $j) (i32.const 1))
              (call $boxInt (i32.or (i32.const 0xDC00) (i32.and (local.get $cp) (i32.const 0x3FF)))))
            (local.set $j (i32.add (local.get $j) (i32.const 2)))))
        (local.set $i (i32.add (local.get $i) (local.get $len)))
        (br $l2)))
    (local.get $out))

  ;; Data.String.CodeUnits.fromCharArray : Array Char (UTF-16 code units) -> $Str (UTF-8)
  (func $rt.fromCharArray (export "fromCharArray") (param $arr eqref) (result eqref)
    (local $va (ref $Vals))
    (local $n i32)
    (local $i i32)
    (local $nbytes i32)
    (local $cp i32)
    (local $u i32)
    (local $lo i32)
    (local $s eqref)
    (local $o i32)
    (local.set $va (ref.cast (ref $Vals) (local.get $arr)))
    (local.set $n (array.len (local.get $va)))
    ;; pass 1: count bytes (combining surrogate pairs into astral code points)
    (block $d1
      (loop $l1
        (br_if $d1 (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $u (call $unboxInt (array.get $Vals (local.get $va) (local.get $i))))
        (local.set $cp (local.get $u))
        (if (i32.and (i32.ge_u (local.get $u) (i32.const 0xD800)) (i32.le_u (local.get $u) (i32.const 0xDBFF)))
          (then (if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $n))
            (then
              (local.set $lo (call $unboxInt (array.get $Vals (local.get $va) (i32.add (local.get $i) (i32.const 1)))))
              (if (i32.and (i32.ge_u (local.get $lo) (i32.const 0xDC00)) (i32.le_u (local.get $lo) (i32.const 0xDFFF)))
                (then
                  (local.set $cp (i32.add (i32.const 0x10000)
                    (i32.or (i32.shl (i32.sub (local.get $u) (i32.const 0xD800)) (i32.const 10))
                            (i32.sub (local.get $lo) (i32.const 0xDC00)))))
                  (local.set $i (i32.add (local.get $i) (i32.const 1)))))))))
        (local.set $nbytes (i32.add (local.get $nbytes) (call $rt.utf8Len (local.get $cp))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l1)))
    ;; pass 2: encode
    (local.set $s (call $strNew (local.get $nbytes)))
    (local.set $i (i32.const 0))
    (block $d2
      (loop $l2
        (br_if $d2 (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $u (call $unboxInt (array.get $Vals (local.get $va) (local.get $i))))
        (local.set $cp (local.get $u))
        (if (i32.and (i32.ge_u (local.get $u) (i32.const 0xD800)) (i32.le_u (local.get $u) (i32.const 0xDBFF)))
          (then (if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $n))
            (then
              (local.set $lo (call $unboxInt (array.get $Vals (local.get $va) (i32.add (local.get $i) (i32.const 1)))))
              (if (i32.and (i32.ge_u (local.get $lo) (i32.const 0xDC00)) (i32.le_u (local.get $lo) (i32.const 0xDFFF)))
                (then
                  (local.set $cp (i32.add (i32.const 0x10000)
                    (i32.or (i32.shl (i32.sub (local.get $u) (i32.const 0xD800)) (i32.const 10))
                            (i32.sub (local.get $lo) (i32.const 0xDC00)))))
                  (local.set $i (i32.add (local.get $i) (i32.const 1)))))))))
        (local.set $o (call $rt.utf8Encode (local.get $s) (local.get $o) (local.get $cp)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l2)))
    (local.get $s))

  ;; Data.Int.fromStringAsImpl just nothing radix str  (parse `str` in base `radix`)
  (func $rt.intFromString (export "intFromString") (param $just eqref) (param $nothing eqref) (param $radix eqref) (param $str eqref) (result eqref)
    (local $n i32)
    (local $i i32)
    (local $b i32)
    (local $r i32)
    (local $acc i32)
    (local $neg i32)
    (local $dig i32)
    (local $any i32)
    (local $valid i32)
    (local.set $r (call $unboxInt (local.get $radix)))
    (local.set $n (call $strLen (local.get $str)))
    (local.set $valid (i32.const 1))
    (if (i32.gt_u (local.get $n) (i32.const 0))
      (then
        (local.set $b (call $strByteAt (local.get $str) (i32.const 0)))
        (if (i32.eq (local.get $b) (i32.const 45)) (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1)))
          (else (if (i32.eq (local.get $b) (i32.const 43)) (then (local.set $i (i32.const 1))))))))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $b (call $strByteAt (local.get $str) (local.get $i)))
        (local.set $dig
          (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 48)) (i32.le_u (local.get $b) (i32.const 57)))
            (then (i32.sub (local.get $b) (i32.const 48)))
            (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 97)) (i32.le_u (local.get $b) (i32.const 122)))
              (then (i32.add (i32.sub (local.get $b) (i32.const 97)) (i32.const 10)))
              (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 65)) (i32.le_u (local.get $b) (i32.const 90)))
                (then (i32.add (i32.sub (local.get $b) (i32.const 65)) (i32.const 10)))
                (else (i32.const -1))))))))
        (if (i32.or (i32.lt_s (local.get $dig) (i32.const 0)) (i32.ge_s (local.get $dig) (local.get $r)))
          (then (local.set $valid (i32.const 0)) (br $done)))
        (local.set $acc (i32.add (i32.mul (local.get $acc) (local.get $r)) (local.get $dig)))
        (local.set $any (i32.const 1))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (if (result eqref) (i32.and (local.get $valid) (local.get $any))
      (then (call $callClo1 (local.get $just)
        (call $boxInt (if (result i32) (local.get $neg) (then (i32.sub (i32.const 0) (local.get $acc))) (else (local.get $acc))))))
      (else (local.get $nothing)))))
