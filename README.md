# cl-parallel

High-performance work-stealing thread pool for SBCL using native threading primitives.

## Features

- **Work-stealing scheduler** - Efficient load balancing across CPU cores using Chase-Lev deques
- **Lock-free data structures** - Minimal contention for high throughput
- **Futures/promises** - Clean async result handling
- **High-level primitives** - `parallel-map`, `parallel-reduce`, `parallel-do`, etc.
- **Zero dependencies** - Pure SBCL, no external libraries

## Requirements

- SBCL (tested on 2.x)
- ASDF

## Installation

```lisp
(asdf:load-system :cl-parallel)
```

## Quick Start

```lisp
(use-package :cl-parallel)

;; Create a thread pool
(defparameter *pool* (make-thread-pool :num-workers 8))

;; Parallel map
(parallel-map *pool* #'expensive-fn items)

;; Parallel reduce
(parallel-reduce *pool* #'+ numbers 0)

;; Submit individual tasks
(let ((future (submit-task *pool* #'compute-something arg1 arg2)))
  (await-result future))

;; Cleanup
(shutdown-thread-pool *pool*)
```

## API Reference

### Thread Pool

- `(make-thread-pool &key num-workers name)` - Create pool (defaults to CPU count)
- `(shutdown-thread-pool pool &key wait timeout)` - Shutdown pool
- `(thread-pool-active-p pool)` - Check if pool is running
- `(submit-task pool fn &rest args)` - Submit task, returns future
- `(await-result future &optional timeout)` - Wait for result
- `(await-all futures &optional timeout)` - Wait for multiple results

### Parallel Primitives

- `(parallel-map pool fn items &key grain-size)` - Map in parallel
- `(parallel-reduce pool fn items identity &key grain-size)` - Reduce in parallel
- `(parallel-do pool fn items &key grain-size)` - Execute for side effects
- `(parallel-count-if pool predicate items)` - Count matching items
- `(parallel-some pool predicate items)` - Find first match
- `(parallel-every pool predicate items)` - Check all match

### Convenience Functions

- `(pmap fn items)` - Parallel map using default pool
- `(preduce fn items identity)` - Parallel reduce using default pool
- `(ensure-thread-pool)` - Get or create default pool

### Statistics

- `(thread-pool-stats pool)` - Get performance statistics
- `(print-pool-stats pool)` - Print formatted stats
- `(reset-pool-stats)` - Reset counters

## Architecture

The work-stealing scheduler uses:

1. **Per-worker deques** - Each worker has a local double-ended queue
2. **Local push/pop** - Workers push/pop from their own deque (no contention)
3. **Remote stealing** - Idle workers steal from other deques (lock-free CAS)
4. **Futures** - Results returned via promise/fulfill pattern

Performance: O(1) task submission, O(log N) work stealing, minimal lock contention.

## Testing

```lisp
(asdf:test-system :cl-parallel)
```

## License

BSD-3-Clause
