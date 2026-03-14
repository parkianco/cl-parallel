;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; cl-parallel.asd - Work-stealing thread pool for SBCL

(asdf:defsystem #:cl-parallel
  :description "High-performance work-stealing thread pool using SBCL native threading"
  :author "Parkian Company LLC"
  :license "BSD-3-Clause"
  :version "0.1.0"
  :depends-on ()
  :serial t
  :components ((:file "package")
               (:module "src"
                :serial t
                :components ((:file "deque")
                             (:file "future")
                             (:file "pool")
                             (:file "primitives")
                             (:file "stats"))))
  :in-order-to ((asdf:test-op (test-op #:cl-parallel/test))))

(asdf:defsystem #:cl-parallel/test
  :description "Tests for cl-parallel"
  :depends-on (#:cl-parallel)
  :serial t
  :components ((:module "test"
                :serial t
                :components ((:file "package")
                             (:file "tests"))))
  :perform (asdf:test-op (o c)
             (let ((result (uiop:symbol-call :cl-parallel.test :run-tests)))
               (unless result
                 (error "Tests failed")))))
