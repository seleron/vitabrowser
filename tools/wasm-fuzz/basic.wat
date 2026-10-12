(module
  (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
  (func (export "mul64") (param i64 i64) (result i64) local.get 0 local.get 1 i64.mul)
  (func (export "sqrt") (param f64) (result f64) local.get 0 f64.sqrt)
  (func (export "f32add") (param f32 f32) (result f32) local.get 0 local.get 1 f32.add)
  (func (export "trap") unreachable)
  (func (export "div") (param i32 i32) (result i32) local.get 0 local.get 1 i32.div_s)
  (func (export "spin") (param i32) (result i32) (local i32)
    (block (loop
      local.get 0 i32.eqz br_if 1
      local.get 1 local.get 0 i32.xor i32.const 1 i32.add local.set 1
      local.get 0 i32.const 1 i32.sub local.set 0
      br 0))
    local.get 1)
  (global $g (export "g") (mut i32) (i32.const 7))
  (func (export "getg") (result i32) global.get $g)
  (memory (export "memory") 1)
  (data (i32.const 16) "hi wasm")
  (func (export "store") (param i32 i32) local.get 0 local.get 1 i32.store8)
  (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
  (table (export "tbl") 2 funcref)
  (elem (i32.const 0) $t0 $t1)
  (func $t0 (result i32) i32.const 100)
  (func $t1 (export "t1") (result i32) i32.const 200)
  (global $started (mut i32) (i32.const 0))
  (func $start i32.const 1 global.set $started)
  (start $start)
  (func (export "started") (result i32) global.get $started))
