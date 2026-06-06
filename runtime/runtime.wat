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

)
