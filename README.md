# oasync

M:N multithreading for Odin. The end goal is to implement virtual threads that 
automatically and quickly parallelize tasks across several os threads.

## usage
Note that this library is in **PRE ALPHA STATE**. It lacks essential features 
and may randomly cause segmented fault.

However, please test out the library and report issues you have encountered.

```odin 
package oasynctest

import oa "../oasync"
import "core:fmt"

child :: proc() {
    fmt.println("hello from child!")
}

child2 :: proc(raw_data: rawptr) {
    data := cast(^string)raw_data
    fmt.println(data^)
}

core :: proc() {
    fmt.println("hello from oasync~")

    // spawn a procedure in a virtual thread
    oa.go(child)

    // allocated on the heap as the stack gets destroyed
    // upon function finishes

    // the default allocator have been swapped with an arena allocator,
    // which frees itself every run
    // temp_allocator is used here instead as we are passing a pointer from 
    // one task to another
    data := new_clone("pass data into childs threads~", context.temp_allocator)
    oa.go(child2, data)
}

main :: proc() {
    coord := oa.Coordinator{}
    cfg := oa.Config {
        // amount of threads to use
        worker_count    = 4,
        // use the main thread as a worker 
        // (does not contribute towards worker_count)
        use_main_thread = true,
    }

    // fire off the async runtime
    oa.init(&coord, cfg, oa.make_task(core))
}
```
