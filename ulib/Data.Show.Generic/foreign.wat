;; ulib: curated wasm FFI for `Data.Show.Generic` (ADR 0012). Fragment (see ulib/_header.wat).
;; `intercalate sep xs`: join already-rendered $Str elements of `xs` with the $Str `sep`.
  (func $intercalate (export "intercalate") (param $sep eqref) (param $xs eqref) (result eqref)
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
