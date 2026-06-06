;; ulib: curated wasm FFI for `Data.String.CodeUnits` (ADR 0012). Fragment (see
;; ulib/_header.wat). UTF-8 ($Str) <-> UTF-16 code unit (Char) codec on the runtime helpers.
(import "rt" "boxInt" (func $boxInt (param i32) (result eqref)))
(import "rt" "unboxInt" (func $unboxInt (param eqref) (result i32)))
(import "rt" "strNew" (func $strNew (param i32) (result eqref)))
(import "rt" "strSetByte" (func $strSetByte (param eqref i32 i32)))
(import "rt" "strLen" (func $strLen (param eqref) (result i32)))
(import "rt" "strByteAt" (func $strByteAt (param eqref i32) (result i32)))

;; byte length of the UTF-8 encoding of a code point (internal)
(func $utf8Len (param $cp i32) (result i32)
  (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x80)) (then (i32.const 1))
    (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x800)) (then (i32.const 2))
      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x10000)) (then (i32.const 3))
        (else (i32.const 4))))))))

;; encode `cp` into `s` at byte offset `o`, returning the next offset (internal)
(func $utf8Encode (param $s eqref) (param $o i32) (param $cp i32) (result i32)
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

;; Data.String.CodeUnits.singleton :: Char -> String
(func (export "singleton") (param $cp i32) (result eqref)
  (local $s eqref)
  (local.set $s (call $strNew (call $utf8Len (local.get $cp))))
  (drop (call $utf8Encode (local.get $s) (i32.const 0) (local.get $cp)))
  (local.get $s))

;; Data.String.CodeUnits.toCharArray :: String -> Array Char
(func (export "toCharArray") (param $str eqref) (result eqref)
  (local $n i32)
  (local $i i32)
  (local $units i32)
  (local $b i32)
  (local $cp i32)
  (local $len i32)
  (local $out (ref $Vals))
  (local $j i32)
  (local.set $n (call $strLen (local.get $str)))
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

;; Data.String.CodeUnits.fromCharArray :: Array Char -> String
(func (export "fromCharArray") (param $arr eqref) (result eqref)
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
      (local.set $nbytes (i32.add (local.get $nbytes) (call $utf8Len (local.get $cp))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l1)))
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
      (local.set $o (call $utf8Encode (local.get $s) (local.get $o) (local.get $cp)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l2)))
  (local.get $s))
