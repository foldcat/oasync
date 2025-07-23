# oasync internal guide
This document detailes how oasync works internally. If you want to
hack oasync or make something similar to it, you are at the right
place.

## how the scheduler works
Oasync uses a task stealing scehduler. A task stealing scheduler
is very simple at it's core. We spawn up worker threads and then
assign each thread a queue. Suppose thread 1 spawns a task,
said task will be pushed into the local queue assigned to thread 1,
vice versa. Said queue is optimized to work in this setting, in
this case a modified chase-lev deque algorithm is used. Check
the paper for a detailed
guide on the deque algorithm.

Each scheduler runs an event loop. Said event loop is very simple,
it continuously takes items from its assigned queue. Should
the queue not be empty and an item is taken out, we will execute
the procedure pointer stored in the task struct.

Suppose thread 1's local queue is empty, but thread 2's local queue
isn't, thread 1 will steal a task from thread 2's local queue. Hence,
we call this kind of scheduler a stealing scheduler.

Stealing is throttled and steal targets are chosen randomly.
We limit the amount of concurrent processes preforming stealing
operations. As it is common for many workers to finish draining
the run queue around the same time, and many workers attempt to steal
at the same time, resulting in many threads attempting to
access the same queues, causing contention.
This is why we randomly select a queue with the linear congruential
algorithm. We also throttle the amount of concurrent stealing threads
to further prevent this issue.

You may notice we have a two queue algorithm. This is due to the modified
chase-lev deque. The original deque can be shrinked and expanded
dynamically, but this creates complexity in resizing. Instead of
sizing the local queue dynamically, whenever the local queue is full,
we push the data into a global queue guarded by a mutex. Workers will
get items from the global queue should it not be empty.

The global queue is a chunked circular queue algorithm. It is like a
linked list, except instead of each node carrying a new item,
each node stores a circular queue. With this we don't have to allocate
more memory whenever a new item is appended, only after a single segment
of the circular queue is full. When a segment is empty, we free the
node.

To summarize:
- first pop item from the local queue
- if the local queue is empty, pop from global queue
- if the global queue is empty, start stealing from other workers

## source code walkthrough
<img width="815" height="957" alt="Untitled Diagram" src="https://github.com/user-attachments/assets/311b978f-f1df-4172-93ac-0b0fbc02052a" />

