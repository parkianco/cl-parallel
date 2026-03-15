;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; package.lisp - Package definition for cl-parallel

(defpackage #:cl-parallel
  (:use #:cl)
  (:export
   ;; Work-Stealing Deque
   #:work-stealing-deque
   #:make-work-stealing-deque
   #:deque-push-bottom
   #:deque-pop-bottom
   #:deque-steal-top
   #:deque-size

   ;; Futures
   #:future
   #:make-future
   #:future-fulfill
   #:future-fail
   #:future-get
   #:future-ready-p

   ;; Thread Pool
   #:thread-pool
   #:make-thread-pool
   #:shutdown-thread-pool
   #:thread-pool-active-p
   #:submit-task
   #:await-result
   #:await-all

   ;; High-Level Parallel Primitives
   #:parallel-map
   #:parallel-reduce
   #:parallel-do
   #:parallel-count-if
   #:parallel-some
   #:parallel-every
   #:parallel-vector-map
   #:parallel-vector-reduce
   #:parallel-batch-process
   #:make-batches

   ;; Global Pool Convenience
   #:*default-thread-pool*
   #:ensure-thread-pool
   #:pmap
   #:preduce

   ;; Statistics
   #:parallel-stats
   #:thread-pool-stats
   #:reset-pool-stats
   #:print-pool-stats
   #:processor-count))
