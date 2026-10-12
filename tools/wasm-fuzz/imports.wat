(module
  (import "env" "cb" (func $cb (param i32) (result i32)))
  (import "env" "thrower" (func $thrower))
  (func (export "callcb") (param i32) (result i32) local.get 0 call $cb i32.const 1 i32.add)
  (func (export "inner") (param i32) (result i32) local.get 0 i32.const 2 i32.mul)
  (func (export "callthrow") call $thrower))
