;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; pool.lisp - Thread pool with work stealing

(in-package #:cl-parallel)

(defstruct (thread-pool (:constructor %make-thread-pool))
  "A pool of worker threads with work-stealing for load balancing."
  (num-workers 4 :type fixnum)
  (workers nil :type list)
  (deques nil :type (or null simple-vector))
  (global-queue (sb-concurrency:make-queue) :type sb-concurrency:queue)
  (shutdown-p nil :type boolean)
  (active-count 0 :type fixnum)
  (lock (sb-thread:make-mutex :name "pool-lock"))
  (work-available (sb-thread:make-waitqueue :name "work-available")))

(defun processor-count ()
  "Return the number of available processors."
  #+sbcl
  (or (let ((env-val (sb-ext:posix-getenv "CL_PARALLEL_WORKERS")))
        (when env-val
          (handler-case (parse-integer env-val)
            (error () nil))))
      (handler-case
          (sb-alien:alien-funcall
           (sb-alien:extern-alien "sysconf"
                                  (function sb-alien:long sb-alien:int))
           84)  ; _SC_NPROCESSORS_ONLN on Linux
        (error ()
          (handler-case
              ;; macOS fallback
              (parse-integer
               (string-trim '(#\Space #\Newline #\Return)
                            (with-output-to-string (s)
                              (uiop:run-program (list "sysctl" "-n" "hw.ncpu")
                                                :output s))))
            (error () 4))))
      4)
  #-sbcl 4)

(defun make-thread-pool (&key (num-workers nil) (name "cl-parallel-worker"))
  "Create a new thread pool with the specified number of workers.
   Defaults to number of CPU cores."
  (let* ((n (or num-workers (processor-count)))
         (pool (%make-thread-pool :num-workers n))
         (deques (make-array n)))
    ;; Initialize per-worker deques
    (dotimes (i n)
      (setf (svref deques i) (make-work-stealing-deque)))
    (setf (thread-pool-deques pool) deques)
    ;; Initialize statistics tracking for this pool
    (init-worker-stats n)
    ;; Start worker threads
    (setf (thread-pool-workers pool)
          (loop for i from 0 below n
                collect (let ((worker-id i))
                          (sb-thread:make-thread
                           (lambda ()
                             (worker-loop pool worker-id))
                           :name (format nil "~A-~D" name worker-id)))))
    pool))

(defun worker-loop (pool worker-id)
  "Main loop for worker thread. Executes tasks from local deque,
   steals from others when idle, or waits on global queue."
  (let ((my-deque (svref (thread-pool-deques pool) worker-id))
        (num-workers (thread-pool-num-workers pool))
        (executed-task nil))
    (tagbody
     :loop-start
       (setf executed-task nil)

       ;; Check for shutdown
       (when (thread-pool-shutdown-p pool)
         (go :exit))

       ;; Try to get task from local deque first (no contention)
       (let ((task (deque-pop-bottom my-deque)))
         (when task
           (execute-task pool task worker-id)
           (go :loop-start)))

       ;; Try to get from global queue
       (let ((task (sb-concurrency:dequeue (thread-pool-global-queue pool))))
         (when task
           (execute-task pool task worker-id)
           (go :loop-start)))

       ;; Try to steal from other workers (work stealing)
       (let ((start (random num-workers)))
         (loop for offset from 0 below num-workers
               for i = (mod (+ start offset) num-workers)
               when (/= i worker-id)
                 do (let ((task (deque-steal-top (svref (thread-pool-deques pool) i))))
                      (record-steal-attempt worker-id (not (null task)))
                      (when task
                        (execute-task pool task worker-id)
                        (setf executed-task t)
                        (return)))))
       (when executed-task
         (go :loop-start))

       ;; No work available, wait briefly then retry
       (sb-thread:with-mutex ((thread-pool-lock pool))
         (unless (thread-pool-shutdown-p pool)
           (sb-thread:condition-wait
            (thread-pool-work-available pool)
            (thread-pool-lock pool)
            :timeout 0.001)))

       (go :loop-start)

     :exit)))

(defun execute-task (pool task &optional (worker-id 0))
  "Execute a single task, handling errors appropriately."
  (declare (ignore pool))
  (let ((start-time (get-internal-real-time)))
    (destructuring-bind (fn future . args) task
      (handler-case
          (let ((result (apply fn args)))
            (future-fulfill future result)
            (record-task-completed worker-id
                                   (- (get-internal-real-time) start-time)))
        (error (e)
          (future-fail future e)
          (record-task-completed worker-id
                                 (- (get-internal-real-time) start-time)))))))

(defun submit-task (pool fn &rest args)
  "Submit a task to the thread pool. Returns a future for the result."
  (let* ((future (make-future))
         (task (list* fn future args)))
    (sb-concurrency:enqueue task (thread-pool-global-queue pool))
    (record-task-submitted)
    ;; Wake up a worker
    (sb-thread:with-mutex ((thread-pool-lock pool))
      (sb-thread:condition-notify (thread-pool-work-available pool)))
    future))

(defun await-result (future &optional (timeout nil))
  "Wait for a future to complete and return its value."
  (future-get future timeout))

(defun await-all (futures &optional (timeout nil))
  "Wait for all futures to complete and return their values as a list."
  (mapcar (lambda (f) (await-result f timeout)) futures))

(defun shutdown-thread-pool (pool &key (wait t) (timeout 5))
  "Shutdown the thread pool, optionally waiting for tasks to complete.
   If WAIT is T, blocks until all workers exit or TIMEOUT seconds elapse."
  (setf (thread-pool-shutdown-p pool) t)
  ;; Wake up all workers so they can see shutdown flag
  (sb-thread:with-mutex ((thread-pool-lock pool))
    (sb-thread:condition-broadcast (thread-pool-work-available pool)))
  (when wait
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second))))
      (dolist (worker (thread-pool-workers pool))
        (let ((remaining (/ (- deadline (get-internal-real-time))
                            internal-time-units-per-second)))
          (when (plusp remaining)
            (sb-thread:join-thread worker :timeout remaining)))))))

(defun thread-pool-active-p (pool)
  "Return T if the thread pool is still active (not shutdown)."
  (not (thread-pool-shutdown-p pool)))
