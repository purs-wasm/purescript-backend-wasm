;; ulib co-located foreign for the Data.Array shadow (ADR 0031): the structural reader foreigns the
;; shadow keeps (reverse/sliceImpl/indexImpl/unconsImpl/rangeImpl). Assembled by `ulib install` into
;; the lib (foreign.wasm). Fragment (wrapped with ulib/_header.wat). The global ulib/Data.Array/
;; foreign.wat is the same content, kept for the (test-only) e2e harness until it is rewritten.
(import "rt" "applyClo" (func $callClo1 (param eqref eqref) (result eqref)))

;; Data.Array.reverse :: Array a -> Array a
(func (export "reverse") (param $xs eqref) (result eqref)
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

;; Data.Array.sliceImpl :: Int -> Int -> Array a -> Array a  (clamped, like JS slice)
(func (export "sliceImpl") (param $start i32) (param $end i32) (param $xs eqref) (result eqref)
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

;; Data.Array.indexImpl :: (a -> Maybe a) -> Maybe a -> Array a -> Int -> Maybe a
(func (export "indexImpl") (param $just eqref) (param $nothing eqref) (param $xs eqref) (param $i i32) (result eqref)
  (local $va (ref $Vals))
  (local.set $va (ref.cast (ref $Vals) (local.get $xs)))
  (if (result eqref)
    (i32.and (i32.ge_s (local.get $i) (i32.const 0)) (i32.lt_u (local.get $i) (array.len (local.get $va))))
    (then (call $callClo1 (local.get $just) (array.get $Vals (local.get $va) (local.get $i))))
    (else (local.get $nothing))))

;; Data.Array.unconsImpl :: (Unit -> b) -> (a -> Array a -> b) -> Array a -> b
(func (export "unconsImpl") (param $empty eqref) (param $next eqref) (param $xs eqref) (result eqref)
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

;; Data.Array.rangeImpl :: Int -> Int -> Array Int  (inclusive; ascending when
;; start <= end, otherwise descending — matching the JS `function (start, end)`).
;; Each element is a freshly boxed `$Int`.
(func (export "rangeImpl") (param $start i32) (param $end i32) (result eqref)
  (local $n i32)
  (local $step i32)
  (local $i i32)
  (local $v i32)
  (local $out (ref $Vals))
  (if (i32.le_s (local.get $start) (local.get $end))
    (then
      (local.set $n (i32.add (i32.sub (local.get $end) (local.get $start)) (i32.const 1)))
      (local.set $step (i32.const 1)))
    (else
      (local.set $n (i32.add (i32.sub (local.get $start) (local.get $end)) (i32.const 1)))
      (local.set $step (i32.const -1))))
  (local.set $out (array.new $Vals (ref.null none) (local.get $n)))
  (local.set $v (local.get $start))
  (block $done
    (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (array.set $Vals (local.get $out) (local.get $i) (struct.new $Int (local.get $v)))
      (local.set $v (i32.add (local.get $v) (local.get $step)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
  (local.get $out))
