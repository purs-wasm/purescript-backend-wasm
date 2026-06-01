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
  (type $LabelIds (array i32))                                      ;; interned record labels (immutable)
  (type $Bytes (array (mut i32)))                                   ;; UTF-8 bytes, one per i32 lane (not packed)
  (type $Rec (struct (field (ref $LabelIds)) (field (ref $Vals))))  ;; parallel labels / values
  (type $Str (struct (field (ref $Bytes))))

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
      (else (local.get $a)))))
