;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

;;;; test/package.lisp - Test package for cl-parallel

(defpackage #:cl-parallel.test
  (:use #:cl #:cl-parallel)
  (:export #:run-tests))
