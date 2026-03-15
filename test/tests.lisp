;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

;;;; test/tests.lisp - Tests for cl-parallel

(in-package #:cl-parallel.test)

(defvar *test-failures* nil)
(defvar *test-count* 0)

(defmacro deftest (name &body body)
  `(progn
     (incf *test-count*)
     (handler-case
         (progn ,@body
                (format t "~&  [PASS] ~A~%" ',name))
       (error (e)
         (push (cons ',name e) *test-failures*)
         (format t "~&  [FAIL] ~A: ~A~%" ',name e)))))

(defmacro assert-equal (expected actual)
  `(unless (equal ,expected ,actual)
     (error "Expected ~S but got ~S" ,expected ,actual)))

(defmacro assert-true (form)
  `(unless ,form
     (error "Expected true but got ~S" ,form)))

(defun run-tests ()
  "Run all tests and return T on success, NIL on failure."
  (setf *test-failures* nil
        *test-count* 0)
  (format t "~&Running cl-parallel tests...~%")

  ;; Deque tests
  (deftest deque-basic
    (let ((dq (make-work-stealing-deque)))
      (deque-push-bottom dq 1)
      (deque-push-bottom dq 2)
      (deque-push-bottom dq 3)
      (assert-equal 3 (deque-size dq))
      (assert-equal 3 (deque-pop-bottom dq))
      (assert-equal 2 (deque-pop-bottom dq))
      (assert-equal 1 (deque-pop-bottom dq))
      (assert-equal nil (deque-pop-bottom dq))))

  (deftest deque-steal
    (let ((dq (make-work-stealing-deque)))
      (deque-push-bottom dq :a)
      (deque-push-bottom dq :b)
      (deque-push-bottom dq :c)
      (assert-equal :a (deque-steal-top dq))
      (assert-equal :b (deque-steal-top dq))
      (assert-equal 1 (deque-size dq))))

  ;; Future tests
  (deftest future-basic
    (let ((f (make-future)))
      (assert-true (not (future-ready-p f)))
      (future-fulfill f 42)
      (assert-true (future-ready-p f))
      (assert-equal 42 (future-get f))))

  (deftest future-timeout
    (let ((f (make-future)))
      (multiple-value-bind (val got) (future-get f 0.01)
        (assert-equal nil val)
        (assert-equal nil got))))

  ;; Thread pool tests
  (deftest pool-basic
    (let ((pool (make-thread-pool :num-workers 2)))
      (unwind-protect
          (let ((fut (submit-task pool (lambda () (+ 1 2)))))
            (assert-equal 3 (await-result fut)))
        (shutdown-thread-pool pool))))

  (deftest pool-multiple-tasks
    (let ((pool (make-thread-pool :num-workers 4)))
      (unwind-protect
          (let ((futures (loop for i from 1 to 10
                               collect (let ((n i))
                                         (submit-task pool (lambda () (* n n)))))))
            (assert-equal '(1 4 9 16 25 36 49 64 81 100) (await-all futures)))
        (shutdown-thread-pool pool))))

  ;; Parallel primitives tests
  (deftest parallel-map-basic
    (let ((pool (make-thread-pool :num-workers 2)))
      (unwind-protect
          (let ((result (parallel-map pool #'1+ '(1 2 3 4 5))))
            (assert-equal '(2 3 4 5 6) result))
        (shutdown-thread-pool pool))))

  (deftest parallel-reduce-basic
    (let ((pool (make-thread-pool :num-workers 2)))
      (unwind-protect
          (let ((result (parallel-reduce pool #'+ '(1 2 3 4 5) 0)))
            (assert-equal 15 result))
        (shutdown-thread-pool pool))))

  (deftest parallel-count-if-basic
    (let ((pool (make-thread-pool :num-workers 2)))
      (unwind-protect
          (let ((result (parallel-count-if pool #'evenp '(1 2 3 4 5 6))))
            (assert-equal 3 result))
        (shutdown-thread-pool pool))))

  (deftest parallel-every-basic
    (let ((pool (make-thread-pool :num-workers 2)))
      (unwind-protect
          (progn
            (assert-true (parallel-every pool #'numberp '(1 2 3 4 5)))
            (assert-true (not (parallel-every pool #'evenp '(1 2 3 4 5)))))
        (shutdown-thread-pool pool))))

  (deftest make-batches-basic
    (assert-equal '((1 2) (3 4) (5)) (make-batches '(1 2 3 4 5) 2))
    (assert-equal '((1 2 3)) (make-batches '(1 2 3) 10)))

  ;; Print summary
  (format t "~&~%Tests completed: ~D passed, ~D failed~%"
          (- *test-count* (length *test-failures*))
          (length *test-failures*))
  (null *test-failures*))
