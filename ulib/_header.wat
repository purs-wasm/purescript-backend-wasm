;; Shared GC value-type header for `ulib/<Module>/foreign.wat` and project-local
;; `<input>/<Module>/foreign.wat` *fragments* (ADR 0010 / 0012).
;;
;; A foreign `.wat` may be written either as a full `(module …)` (declaring its own types)
;; or as a **fragment** — `(import …)` and `(func …)` forms with no `(module …)` wrapper and
;; no type declarations. For a fragment, `bin` wraps it as `(module <this header> <fragment>)`
;; before assembling, so every foreign shares ONE authoritative copy of the runtime value
;; types and they canonicalize identically across the merged modules (`wasm-merge`). The
;; runtime-core helpers a fragment uses are imported per module from "rt"
;; (e.g. `(import "rt" "applyClo" (func $callClo1 (param eqref eqref) (result eqref)))`).
(type $Vals (array (mut eqref))) ;; Array a / a record's value row
(type $LabelIds (array (mut i32))) ;; interned record label ids
(type $Bytes (array (mut i32))) ;; UTF-8 bytes, one per i32 lane
(type $Rec (struct (field (ref $LabelIds)) (field (ref $Vals)))) ;; a record
(type $Str (struct (field (ref $Bytes)))) ;; a String
(type $Int (struct (field i32))) ;; boxed Int (also Char)
(type $Num (struct (field f64))) ;; boxed Number
(type $Clo (struct (field funcref) (field (ref $Vals)))) ;; a closure
(type $Code (func (param (ref $Clo) eqref) (result eqref))) ;; lifted closure body
(type $Ref (struct (field (mut eqref)))) ;; Effect.Ref / ST cell
