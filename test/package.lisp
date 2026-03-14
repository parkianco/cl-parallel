;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; test/package.lisp - Test package for cl-parallel

(defpackage #:cl-parallel.test
  (:use #:cl #:cl-parallel)
  (:export #:run-tests))
