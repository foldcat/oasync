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

import oasync "../oasync"
import "core:fmt"

child :: proc(t: oasync.Worker) {
	fmt.println("hi from child task")
}

core :: proc(t: oasync.Worker) {
  fmt.println("test")
	oasync.spawn_task(oasync.make_task(child))
}

main :: proc() {
  coord := oasync.Coordinator{}
  cfg := oasync.Config {
    worker_count    = 4,
    use_main_thread = true,
  }
  oasync.init(&coord, cfg, oasync.make_task(core))
}
```
