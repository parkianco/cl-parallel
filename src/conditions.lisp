;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-parallel)

(define-condition cl-parallel-error (error)
  ((message :initarg :message :reader cl-parallel-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-parallel error: ~A" (cl-parallel-error-message condition)))))
