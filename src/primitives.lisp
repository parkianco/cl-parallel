;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; primitives.lisp - High-level parallel primitives

(in-package #:cl-parallel)

;;; ============================================================================
;;; High-Level Parallel Primitives
;;; ============================================================================

(defun parallel-map (pool fn items &key (grain-size 1))
  "Apply FN to each item in ITEMS in parallel, returning results in order.
   GRAIN-SIZE controls chunking - larger values reduce overhead for cheap FN."
  (if (<= (length items) grain-size)
      ;; For small inputs, just run sequentially
      (mapcar fn items)
      ;; Split into chunks and process in parallel
      (let* ((n (length items))
             (chunk-size (max grain-size (ceiling n (thread-pool-num-workers pool))))
             (chunks (loop for i from 0 below n by chunk-size
                           collect (subseq items i (min (+ i chunk-size) n))))
             (futures (mapcar (lambda (chunk)
                                (submit-task pool
                                             (lambda ()
                                               (mapcar fn chunk))))
                              chunks)))
        ;; Collect results in order
        (apply #'append (await-all futures)))))

(defun parallel-reduce (pool fn items identity &key (grain-size 8))
  "Reduce ITEMS using FN in parallel, with IDENTITY as initial value.
   FN must be associative for correct results."
  (if (<= (length items) grain-size)
      ;; Sequential reduction for small inputs
      (reduce fn items :initial-value identity)
      ;; Parallel tree reduction
      (let* ((n (length items))
             (chunk-size (max grain-size (ceiling n (thread-pool-num-workers pool))))
             (chunks (loop for i from 0 below n by chunk-size
                           collect (subseq items i (min (+ i chunk-size) n))))
             (futures (mapcar (lambda (chunk)
                                (submit-task pool
                                             (lambda ()
                                               (reduce fn chunk :initial-value identity))))
                              chunks))
             (partial-results (await-all futures)))
        ;; Reduce partial results
        (reduce fn partial-results :initial-value identity))))

(defun parallel-do (pool fn items &key (grain-size 1))
  "Execute FN on each item in ITEMS in parallel for side effects.
   Blocks until all items are processed."
  (let* ((n (length items))
         (chunk-size (max grain-size (ceiling n (thread-pool-num-workers pool))))
         (chunks (loop for i from 0 below n by chunk-size
                       collect (subseq items i (min (+ i chunk-size) n))))
         (futures (mapcar (lambda (chunk)
                            (submit-task pool
                                         (lambda ()
                                           (mapc fn chunk)
                                           t)))
                          chunks)))
    (await-all futures)
    nil))

(defun parallel-count-if (pool predicate items &key (grain-size 16))
  "Count items satisfying PREDICATE in parallel."
  (parallel-reduce pool #'+
                   (parallel-map pool
                                 (lambda (x) (if (funcall predicate x) 1 0))
                                 items
                                 :grain-size grain-size)
                   0))

(defun parallel-some (pool predicate items &key (grain-size 16))
  "Return first item satisfying PREDICATE, or NIL if none.
   May return any satisfying item due to parallel execution."
  (let* ((found-value nil)
         (found-p nil)
         (lock (sb-thread:make-mutex :name "parallel-some")))
    (parallel-do pool
                 (lambda (x)
                   (unless found-p
                     (when (funcall predicate x)
                       (sb-thread:with-mutex (lock)
                         (unless found-p
                           (setf found-p t
                                 found-value x))))))
                 items
                 :grain-size grain-size)
    (values found-value found-p)))

(defun parallel-every (pool predicate items &key (grain-size 16))
  "Return T if all items satisfy PREDICATE, NIL otherwise."
  (let ((all-pass t))
    (parallel-do pool
                 (lambda (x)
                   (when all-pass
                     (unless (funcall predicate x)
                       (setf all-pass nil))))
                 items
                 :grain-size grain-size)
    all-pass))

;;; ============================================================================
;;; Parallel Vector/Array Operations
;;; ============================================================================

(defun parallel-vector-map (pool fn vec &key (grain-size 64))
  "Apply FN to each element of VEC in parallel, returning a new vector."
  (let* ((n (length vec))
         (result (make-array n))
         (chunk-size (max grain-size (ceiling n (thread-pool-num-workers pool))))
         (futures nil))
    (loop for start from 0 below n by chunk-size
          for end = (min (+ start chunk-size) n)
          do (push (submit-task pool
                                (lambda ()
                                  (loop for i from start below end
                                        do (setf (aref result i)
                                                 (funcall fn (aref vec i))))
                                  t))
                   futures))
    (await-all futures)
    result))

(defun parallel-vector-reduce (pool fn vec identity &key (grain-size 64))
  "Reduce vector VEC using FN in parallel."
  (coerce (parallel-reduce pool fn (coerce vec 'list) identity :grain-size grain-size)
          (type-of vec)))

;;; ============================================================================
;;; Batch Processing Utilities
;;; ============================================================================

(defun parallel-batch-process (pool fn batches &key (combine #'append))
  "Process BATCHES in parallel and combine results.
   FN is called on each batch and should return a list.
   COMBINE function merges results (default: APPEND)."
  (let ((futures (mapcar (lambda (batch)
                           (submit-task pool fn batch))
                         batches)))
    (reduce combine (await-all futures) :initial-value nil)))

(defun make-batches (items batch-size)
  "Split ITEMS into batches of BATCH-SIZE."
  (loop for i from 0 below (length items) by batch-size
        collect (subseq items i (min (+ i batch-size) (length items)))))

;;; ============================================================================
;;; Global Thread Pool (for convenience)
;;; ============================================================================

(defvar *default-thread-pool* nil
  "Default thread pool for parallel operations.")

(defun ensure-thread-pool ()
  "Ensure the default thread pool exists."
  (unless *default-thread-pool*
    (setf *default-thread-pool* (make-thread-pool)))
  *default-thread-pool*)

(defun pmap (fn items &key (grain-size 1))
  "Parallel map using the default thread pool."
  (parallel-map (ensure-thread-pool) fn items :grain-size grain-size))

(defun preduce (fn items identity &key (grain-size 8))
  "Parallel reduce using the default thread pool."
  (parallel-reduce (ensure-thread-pool) fn items identity :grain-size grain-size))
