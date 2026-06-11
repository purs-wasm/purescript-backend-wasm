;; ulib co-located foreign for the Data.Show shadow (ADR 0031): ONLY showNumberImpl — the Dragon4
;; (Steele-White / Burger-Dybvig) shortest-round-trip f64 formatter the shadow keeps as a foreign
;; (Number->string needs a Ryu/Grisu-class algorithm). Assembled by `ulib install` into the lib
;; (foreign.wasm). Fragment (wrapped with ulib/_header.wat). The other show*Impl are PureScript in
;; the shadow. The global ulib/Data.Show/foreign.wat keeps all 5 for the (test-only) e2e harness.

;; ---- internal byte-building helpers ----
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

;; ---- the five Data.Show foreigns ----
  (func $showNumber (export "showNumberImpl") (param $x f64) (result eqref)
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
