# Example: Metatheory of 2nd-ordered λ calculus

## Syntax

```plain
;; variables
V = (alphanumeric + ' + _, starting with lower case character)

Id -- identifier, same rule as V

;; infix operator
Op := +   -- addition
      *   -- multiplication
      -   -- subtraction
      ==  -- integer equator

;; types
T := V          -- type variable
     T -> T     -- arrow type
     ∀ V. T     -- Pi type

;; terms
t := V                    -- term variable
     Id                   -- identifier
     t OP t               -- infix operator
     fun (V:T) -> t       -- 1st order abstraction
     t t                  -- 1st order application
     let v = t in t       -- let local binding
     if t then t else t   -- conditional
     fun (V:*) -> t       -- 2nd order abstraction
     t [T]                -- 2nd order application
```

### Note

- operators precedence follows ordinary methmatics (`*` > `+`,`-` > `==`)

- curried function can have single `fun` keyword at the head (fun-normal form). E.g.:

  ```plain
  id = fun (α:*) (x:α) -> x 
  ```
