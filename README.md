# oasync

M:N multithreading for Odin, based on Tokio's model. The end goal is to 
allow fiber based concurrency model that can run a large number of smaller 
tasks, automatically and quickly parallelized and distributed on several threads.

## usage
Note that this library is in **PRE ALPHA STATE**. It lacks essential features 
and will randomly cause segmented fault.

However, please try out the library and submit issues (I will be greatful).
The code below is a great starting point

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
