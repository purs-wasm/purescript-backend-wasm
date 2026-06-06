;; ulib: curated wasm FFI for `Data.Foldable` (ADR 0012). Fragment (see ulib/_header.wat).
(import "rt" "applyClo" (func $callClo1 (param eqref eqref) (result eqref)))

;; Data.Foldable.foldlArray :: (b -> a -> b) -> b -> Array a -> b
(func (export "foldlArray") (param $f eqref) (param $z eqref) (param $xs eqref) (result eqref)
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

;; Data.Foldable.foldrArray :: (a -> b -> b) -> b -> Array a -> b
(func (export "foldrArray") (param $f eqref) (param $z eqref) (param $xs eqref) (result eqref)
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
