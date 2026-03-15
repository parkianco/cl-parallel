;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; stats.lisp - Performance monitoring and statistics

(in-package #:cl-parallel)

;;; ============================================================================
;;; Performance Monitoring
;;; ============================================================================

(defstruct parallel-stats
  "Statistics for parallel execution."
  (tasks-submitted 0 :type fixnum)
  (tasks-completed 0 :type fixnum)
  (tasks-stolen 0 :type fixnum)
  (total-wait-time 0 :type fixnum)
  (total-execute-time 0 :type fixnum)
  (avg-task-time 0.0 :type single-float)
  (worker-utilization nil :type list)
  (queue-depths nil :type list)
  (steal-success-rate 0.0 :type single-float))

;;; Per-worker statistics tracking
(defstruct worker-stats
  "Statistics for an individual worker thread."
  (tasks-executed 0 :type fixnum)
  (tasks-stolen 0 :type fixnum)
  (steal-attempts 0 :type fixnum)
  (total-busy-time 0 :type fixnum)
  (total-idle-time 0 :type fixnum)
  (last-active-time 0 :type fixnum))

(defvar *worker-stats* nil
  "Vector of worker-stats structures, one per worker.")

(defvar *global-stats-lock* nil
  "Lock for updating global statistics.")

(defun ensure-global-stats-lock ()
  "Thread-safe lazy initialization of global-stats-lock."
  (or *global-stats-lock*
      (sb-ext:compare-and-swap (symbol-value '*global-stats-lock*) nil
        (sb-thread:make-mutex :name "global-stats-lock"))))

(defvar *global-tasks-submitted* 0
  "Total tasks submitted to any pool.")

(defvar *global-tasks-completed* 0
  "Total tasks completed across all pools.")

(defvar *global-tasks-stolen* 0
  "Total tasks stolen via work-stealing.")

(defvar *global-execute-time* 0
  "Total execution time in internal units.")

(defun init-worker-stats (num-workers)
  "Initialize worker statistics tracking for NUM-WORKERS."
  (setf *worker-stats* (make-array num-workers))
  (dotimes (i num-workers)
    (setf (svref *worker-stats* i)
          (make-worker-stats :last-active-time (get-internal-real-time)))))

(defun record-task-submitted ()
  "Record that a task was submitted."
  (sb-thread:with-mutex ((ensure-global-stats-lock))
    (incf *global-tasks-submitted*)))

(defun record-task-completed (worker-id execution-time-internal-units)
  "Record that a task was completed by WORKER-ID."
  (sb-thread:with-mutex ((ensure-global-stats-lock))
    (incf *global-tasks-completed*)
    (incf *global-execute-time* execution-time-internal-units))
  (when (and *worker-stats* (< worker-id (length *worker-stats*)))
    (let ((ws (svref *worker-stats* worker-id)))
      (incf (worker-stats-tasks-executed ws))
      (incf (worker-stats-total-busy-time ws) execution-time-internal-units)
      (setf (worker-stats-last-active-time ws) (get-internal-real-time)))))

(defun record-steal-attempt (worker-id success-p)
  "Record a work-stealing attempt by WORKER-ID."
  (when (and *worker-stats* (< worker-id (length *worker-stats*)))
    (let ((ws (svref *worker-stats* worker-id)))
      (incf (worker-stats-steal-attempts ws))
      (when success-p
        (incf (worker-stats-tasks-stolen ws))
        (sb-thread:with-mutex ((ensure-global-stats-lock))
          (incf *global-tasks-stolen*))))))

(defun thread-pool-stats (pool)
  "Return statistics about thread pool performance.

Returns a PARALLEL-STATS structure with:
  - tasks-submitted: Total tasks submitted to this pool
  - tasks-completed: Total tasks that finished execution
  - tasks-stolen: Tasks transferred via work-stealing
  - total-wait-time: Cumulative time tasks waited in queue
  - total-execute-time: Cumulative task execution time
  - avg-task-time: Average per-task execution time (seconds)
  - worker-utilization: Per-worker busy ratio (0.0 to 1.0)
  - queue-depths: Current depth of each worker's deque
  - steal-success-rate: Ratio of successful steals to attempts"
  (let* ((num-workers (thread-pool-num-workers pool))
         (deques (thread-pool-deques pool))
         (queue-depths (when deques
                        (loop for i from 0 below num-workers
                              collect (deque-size (svref deques i)))))
         (worker-utilization
           (when *worker-stats*
             (loop for i from 0 below (min num-workers (length *worker-stats*))
                   for ws = (svref *worker-stats* i)
                   for busy = (worker-stats-total-busy-time ws)
                   for total = (+ busy (worker-stats-total-idle-time ws))
                   collect (if (zerop total) 0.0 (/ (float busy) total)))))
         (total-steal-attempts
           (if *worker-stats*
               (loop for i from 0 below (min num-workers (length *worker-stats*))
                     sum (worker-stats-steal-attempts (svref *worker-stats* i)))
               0))
         (steal-success-rate
           (if (zerop total-steal-attempts)
               0.0
               (/ (float *global-tasks-stolen*) total-steal-attempts)))
         (avg-task-time
           (if (zerop *global-tasks-completed*)
               0.0
               (/ (float *global-execute-time*)
                  (* *global-tasks-completed* internal-time-units-per-second)))))
    (make-parallel-stats
     :tasks-submitted *global-tasks-submitted*
     :tasks-completed *global-tasks-completed*
     :tasks-stolen *global-tasks-stolen*
     :total-wait-time 0
     :total-execute-time *global-execute-time*
     :avg-task-time avg-task-time
     :worker-utilization worker-utilization
     :queue-depths queue-depths
     :steal-success-rate steal-success-rate)))

(defun reset-pool-stats ()
  "Reset all pool statistics counters."
  (sb-thread:with-mutex ((ensure-global-stats-lock))
    (setf *global-tasks-submitted* 0
          *global-tasks-completed* 0
          *global-tasks-stolen* 0
          *global-execute-time* 0))
  (when *worker-stats*
    (dotimes (i (length *worker-stats*))
      (let ((ws (svref *worker-stats* i)))
        (setf (worker-stats-tasks-executed ws) 0
              (worker-stats-tasks-stolen ws) 0
              (worker-stats-steal-attempts ws) 0
              (worker-stats-total-busy-time ws) 0
              (worker-stats-total-idle-time ws) 0))))
  t)

(defun print-pool-stats (pool &optional (stream *standard-output*))
  "Print formatted pool statistics to STREAM."
  (let ((stats (thread-pool-stats pool)))
    (format stream "~&=== Thread Pool Statistics ===~%")
    (format stream "Tasks submitted:    ~D~%" (parallel-stats-tasks-submitted stats))
    (format stream "Tasks completed:    ~D~%" (parallel-stats-tasks-completed stats))
    (format stream "Tasks stolen:       ~D~%" (parallel-stats-tasks-stolen stats))
    (format stream "Avg task time:      ~,4Fs~%" (parallel-stats-avg-task-time stats))
    (format stream "Steal success rate: ~,1F%~%" (* 100 (parallel-stats-steal-success-rate stats)))
    (format stream "Queue depths:       ~{~D~^ ~}~%" (parallel-stats-queue-depths stats))
    (format stream "Worker utilization: ~{~,1F%~^ ~}~%"
            (mapcar (lambda (u) (* 100 u)) (or (parallel-stats-worker-utilization stats) '())))
    stats))
