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
    fmt.println("hi from child task")
}

core :: proc() {
    fmt.println("test")
    // spawn a procedure in a virtual thread
    oa.go(child)
}

main :: proc() {
    coord := oa.Coordinator{}
    cfg := oa.Config {
        // amount of threads to use
        worker_count    = 4,
        // use the main thread as a worker (does not contribute towards worker_count)
        use_main_thread = true,
    }

    // fire off the async runtime
    oa.init(&coord, cfg, oa.make_task(core))
}
```
