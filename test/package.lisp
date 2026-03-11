;;;; test/package.lisp - Test package for cl-parallel

(defpackage #:cl-parallel.test
  (:use #:cl #:cl-parallel)
  (:export #:run-tests))
