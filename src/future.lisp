;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; future.lisp - Future/Promise for asynchronous task results

(in-package #:cl-parallel)

(defstruct (future (:constructor %make-future))
  "A future representing an asynchronous computation result."
  (value nil)
  (ready-p nil :type boolean)
  (error nil)
  (lock (sb-thread:make-mutex :name "future-lock"))
  (condition (sb-thread:make-waitqueue :name "future-condition")))

(defun make-future ()
  "Create a new unfulfilled future."
  (%make-future))

(defun future-fulfill (future value)
  "Fulfill the future with the given value."
  (sb-thread:with-mutex ((future-lock future))
    (setf (future-value future) value)
    (setf (future-ready-p future) t)
    (sb-thread:condition-broadcast (future-condition future)))
  value)

(defun future-fail (future error)
  "Mark the future as failed with the given error."
  (sb-thread:with-mutex ((future-lock future))
    (setf (future-error future) error)
    (setf (future-ready-p future) t)
    (sb-thread:condition-broadcast (future-condition future)))
  nil)

(defun future-get (future &optional (timeout nil))
  "Get the result of a future, blocking until ready.
   If TIMEOUT is specified (in seconds), return NIL if not ready in time.
   Signals an error if the computation failed."
  (sb-thread:with-mutex ((future-lock future))
    (loop until (future-ready-p future)
          do (if timeout
                 (unless (sb-thread:condition-wait
                          (future-condition future)
                          (future-lock future)
                          :timeout timeout)
                   (return-from future-get (values nil nil)))
                 (sb-thread:condition-wait
                  (future-condition future)
                  (future-lock future)))))
  (when (future-error future)
    (error (future-error future)))
  (values (future-value future) t))

(defun future-ready-p-check (future)
  "Check if future is ready without blocking."
  (future-ready-p future))
