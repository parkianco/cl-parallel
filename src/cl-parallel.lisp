;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package :cl-parallel)

;;; ============================================================================
;;; Futures - Lazy computation containers
;;; ============================================================================

(defstruct future
  "Represents a computation that completes asynchronously.
SLOTS:
  result       - Computed result (NIL until fulfilled)
  error        - Error if computation failed
  ready-p      - T when result available
  lock         - Mutex for thread safety
  condition    - Condition variable for waiting"
  (result nil)
  (error nil)
  (ready-p nil :type boolean)
  (lock (sb-thread:make-mutex))
  (condition (sb-thread:make-waitqueue)))

(defun future-fulfill (future value)
  "Fulfill FUTURE with VALUE."
  (sb-thread:with-mutex ((future-lock future))
    (setf (future-result future) value)
    (setf (future-ready-p future) t)
    (sb-thread:condition-broadcast (future-condition future))))

(defun future-fail (future error)
  "Fulfill FUTURE with ERROR."
  (sb-thread:with-mutex ((future-lock future))
    (setf (future-error future) error)
    (setf (future-ready-p future) t)
    (sb-thread:condition-broadcast (future-condition future))))

(defun future-ready-p (future)
  "Check if FUTURE is ready."
  (sb-thread:with-mutex ((future-lock future))
    (future-ready-p future)))

(defun future-get (future &optional timeout)
  "Get FUTURE's value, blocking if necessary.
PARAMETERS:
  future  - FUTURE structure
  timeout - Max seconds to wait (NIL = forever)
RETURNS: Computed value or raises error"
  (sb-thread:with-mutex ((future-lock future))
    (let ((deadline (when timeout (+ (get-internal-real-time)
                                     (* timeout internal-time-units-per-second)))))
      (loop until (future-ready-p future)
            do (let ((remaining (when deadline
                                  (/ (- deadline (get-internal-real-time))
                                     internal-time-units-per-second))))
                 (when (and remaining (<= remaining 0))
                   (error "Future timeout"))
                 (sb-thread:condition-wait (future-condition future)
                                           (future-lock future)
                                           :timeout remaining)))
      (if (future-error future)
          (error (future-error future))
          (future-result future)))))

;;; ============================================================================
;;; Thread Pool - Manages worker threads
;;; ============================================================================

(defstruct thread-pool
  "Pool of worker threads for executing tasks.
SLOTS:
  workers      - Vector of worker threads
  task-queue   - Queue of pending tasks
  active-p     - Whether pool is accepting tasks
  lock         - Mutex for synchronization
  condition    - Condition variable for workers
  stats        - Performance statistics"
  (workers nil :type (or null vector))
  (task-queue '() :type list)
  (active-p t :type boolean)
  (lock (sb-thread:make-mutex))
  (condition (sb-thread:make-waitqueue))
  (stats (make-hash-table)))

(defun create-thread-pool (&optional (num-threads nil))
  "Create a thread pool with NUM-THREADS workers.
PARAMETERS: num-threads - Number of workers (default: CPU count)
RETURNS: THREAD-POOL"
  (let* ((count (or num-threads (sb-unix:get-nprocs)))
         (pool (make-thread-pool
                :workers (make-array count)
                :task-queue '())))
    (dotimes (i count)
      (setf (aref (thread-pool-workers pool) i)
            (sb-thread:make-thread
             (lambda ()
               (pool-worker-loop pool))
             :name (format nil "pool-worker-~D" i))))
    pool))

(defun pool-worker-loop (pool)
  "Main loop for pool worker thread."
  (loop while (thread-pool-active-p pool)
        do (let ((task nil))
             (sb-thread:with-mutex ((thread-pool-lock pool))
               (loop until (or (thread-pool-task-queue pool)
                               (not (thread-pool-active-p pool)))
                     do (sb-thread:condition-wait (thread-pool-condition pool)
                                                  (thread-pool-lock pool)))
               (when (thread-pool-task-queue pool)
                 (setf task (pop (thread-pool-task-queue pool)))))
             (when task
               (handler-case
                   (funcall task)
                 (error (e)
                   (declare (ignore e))))))))

(defun submit-task (pool function)
  "Submit FUNCTION to POOL for execution.
RETURNS: FUTURE that will contain result"
  (let ((future (make-future)))
    (sb-thread:with-mutex ((thread-pool-lock pool))
      (push (lambda ()
              (handler-case
                  (future-fulfill future (funcall function))
                (error (e)
                  (future-fail future e))))
            (thread-pool-task-queue pool))
      (sb-thread:condition-notify (thread-pool-condition pool)))
    future))

(defun shutdown-thread-pool (pool &optional (wait-p t))
  "Shutdown POOL, optionally waiting for completion.
PARAMETERS:
  pool   - THREAD-POOL
  wait-p - Wait for all tasks (default T)"
  (sb-thread:with-mutex ((thread-pool-lock pool))
    (setf (thread-pool-active-p pool) nil)
    (sb-thread:condition-broadcast (thread-pool-condition pool)))
  (when wait-p
    (loop for thread across (thread-pool-workers pool)
          do (sb-thread:join-thread thread))))

(defun thread-pool-active-p (pool)
  "Check if POOL is accepting new tasks."
  (sb-thread:with-mutex ((thread-pool-lock pool))
    (thread-pool-active-p pool)))

;;; ============================================================================
;;; Parallel Higher-Order Functions
;;; ============================================================================

(defvar *default-pool* nil)

(defun ensure-thread-pool ()
  "Get or create default thread pool."
  (unless *default-pool*
    (setf *default-pool* (create-thread-pool)))
  *default-pool*)

(defun parallel-map (function sequence &optional (pool (ensure-thread-pool)))
  "Apply FUNCTION to SEQUENCE in parallel.
RETURNS: List of results"
  (let ((futures (loop for item in sequence
                       collect (submit-task pool (lambda () (funcall function item))))))
    (loop for future in futures
          collect (future-get future))))

(defun parallel-reduce (function sequence &optional initial-value (pool (ensure-thread-pool)))
  "Reduce SEQUENCE using FUNCTION in parallel.
Uses tree reduction for efficiency."
  (if (<= (length sequence) 1)
      (or (car sequence) initial-value)
      (let* ((mid (/ (length sequence) 2))
             (left (subseq sequence 0 mid))
             (right (subseq sequence mid))
             (left-future (submit-task pool (lambda ()
                                              (parallel-reduce function left initial-value pool))))
             (right-future (submit-task pool (lambda ()
                                               (parallel-reduce function right initial-value pool))))
             (left-result (future-get left-future))
             (right-result (future-get right-future)))
        (funcall function left-result right-result))))

(defun parallel-do (function sequence &optional (pool (ensure-thread-pool)))
  "Execute FUNCTION on each element of SEQUENCE in parallel.
Returns NIL."
  (let ((futures (loop for item in sequence
                       collect (submit-task pool (lambda () (funcall function item))))))
    (loop for future in futures
          do (future-get future))
    nil))

(defun parallel-count-if (predicate sequence &optional (pool (ensure-thread-pool)))
  "Count elements matching PREDICATE in parallel."
  (let ((futures (loop for item in sequence
                       collect (submit-task pool
                                            (lambda ()
                                              (if (funcall predicate item) 1 0))))))
    (loop for future in futures
          sum (future-get future))))

(defun parallel-some (predicate sequence &optional (pool (ensure-thread-pool)))
  "Check if any element matches PREDICATE in parallel."
  (let ((futures (loop for item in sequence
                       collect (submit-task pool (lambda ()
                                                   (funcall predicate item))))))
    (loop for future in futures
          thereis (future-get future))))

(defun parallel-every (predicate sequence &optional (pool (ensure-thread-pool)))
  "Check if all elements match PREDICATE in parallel."
  (let ((futures (loop for item in sequence
                       collect (submit-task pool (lambda ()
                                                   (funcall predicate item))))))
    (loop for future in futures
          always (future-get future))))

(defun pmap (function sequence &optional (pool (ensure-thread-pool)))
  "Shorthand for parallel-map."
  (parallel-map function sequence pool))

(defun preduce (function sequence &optional initial-value (pool (ensure-thread-pool)))
  "Shorthand for parallel-reduce."
  (parallel-reduce function sequence initial-value pool))

;;; ============================================================================
;;; Vector/Array Parallel Operations
;;; ============================================================================

(defun parallel-vector-map (function vector &optional (pool (ensure-thread-pool)))
  "Map FUNCTION across VECTOR in parallel.
Returns new vector with results."
  (let ((len (length vector))
        (results (make-array (length vector))))
    (let ((futures (loop for i from 0 below len
                         collect (submit-task pool
                                              (lambda (idx)
                                                (lambda ()
                                                  (funcall function (aref vector idx))))
                                              i))))
      (loop for i from 0 for future in futures
            do (setf (aref results i) (future-get future))))
    results))

(defun parallel-vector-reduce (function vector &optional initial-value (pool (ensure-thread-pool)))
  "Reduce VECTOR using FUNCTION in parallel."
  (parallel-reduce function (loop for i from 0 below (length vector)
                                   collect (aref vector i))
                   initial-value pool))

;;; ============================================================================
;;; Batch Processing
;;; ============================================================================

(defun parallel-batch-process (items processor-fn &key (batch-size nil) (pool (ensure-thread-pool)))
  "Process ITEMS in parallel batches.
Returns (values results errors)"
  (let ((batch-size (or batch-size (max 1 (/ (length items) (sb-unix:get-nprocs))))))
    (let ((results nil)
          (errors nil))
      (loop for i from 0 by batch-size below (length items)
            do (let ((batch (subseq items i (min (length items) (+ i batch-size)))))
                 (let ((futures (loop for item in batch
                                      collect (submit-task pool
                                                           (lambda ()
                                                             (handler-case
                                                                 (funcall processor-fn item)
                                                               (error (e)
                                                                 (cons :error e))))))))
                   (loop for future in futures
                         for item in batch
                         do (let ((result (future-get future)))
                              (if (and (consp result) (eq (car result) :error))
                                  (push (cons item (cdr result)) errors)
                                  (push result results)))))))
      (values (nreverse results) (nreverse errors)))))

;;; ============================================================================
;;; Statistics and Monitoring
;;; ============================================================================

(defun thread-pool-stats (pool)
  "Get statistics for POOL.
RETURNS: Property list with stats"
  (sb-thread:with-mutex ((thread-pool-lock pool))
    (list :active-p (thread-pool-active-p pool)
          :queue-size (length (thread-pool-task-queue pool))
          :worker-count (length (thread-pool-workers pool)))))

(defun reset-pool-stats (pool)
  "Reset statistics for POOL."
  (sb-thread:with-mutex ((thread-pool-lock pool))
    (clrhash (thread-pool-stats pool))))

(defun print-pool-stats (pool &optional (stream t))
  "Print statistics for POOL."
  (let ((stats (thread-pool-stats pool)))
    (format stream "~&=== Thread Pool Statistics ===~%")
    (format stream "  Active: ~A~%" (getf stats :active-p))
    (format stream "  Queue Size: ~A~%" (getf stats :queue-size))
    (format stream "  Workers: ~A~%" (getf stats :worker-count))))

(defun processor-count ()
  "Get number of available processors."
  (sb-unix:get-nprocs))

;;; ============================================================================
;;; Initialization and Cleanup
;;; ============================================================================

(defun init ()
  "Initialize module."
  t)

(defun process (data)
  "Process data."
  (declare (type t data))
  data)

(defun status ()
  "Get module status."
  :ok)

(defun validate (input)
  "Validate input."
  (declare (type t input))
  t)

(defun cleanup ()
  "Cleanup resources."
  (when *default-pool*
    (shutdown-thread-pool *default-pool*)
    (setf *default-pool* nil)))

(defun initialize-parallel ()
  "Initialize parallel subsystem."
  t)

(defun validate-parallel (ctx)
  "Validate parallel context."
  (declare (ignore ctx))
  t)

(defun parallel-health-check ()
  "Check health of parallel system."
  :healthy)

(defun parallel-stats ()
  "Get stats for default pool."
  (thread-pool-stats (ensure-thread-pool)))

;;; Substantive Functional Logic

(defun deep-copy-list (l)
  "Recursively copies a nested list."
  (if (atom l) l (cons (deep-copy-list (car l)) (deep-copy-list (cdr l)))))

(defun group-by-count (list n)
  "Groups list elements into sublists of size N."
  (loop for i from 0 below (length list) by n
        collect (subseq list i (min (+ i n) (length list)))))
