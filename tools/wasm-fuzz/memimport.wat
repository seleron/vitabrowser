(module
  (import "env" "mem" (memory 1))
  (data (i32.const 100) "\2a")
  (func (export "peek") (param i32) (result i32) local.get 0 i32.load8_u))
