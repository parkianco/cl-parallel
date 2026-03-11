;;;; deque.lisp - Lock-free work-stealing deque
;;;;
;;;; Implementation of Chase-Lev work-stealing deque. Each worker owns a deque
;;;; and pushes/pops from the "bottom" (local operations). Other workers can
;;;; steal from the "top" (requires CAS for thread safety).
;;;;
;;;; Reference: "Dynamic Circular Work-Stealing Deque" - Chase & Lev, SPAA 2005

(in-package #:cl-parallel)

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-concurrency))

(defstruct (work-stealing-deque (:constructor %make-work-stealing-deque))
  "A lock-free work-stealing deque for efficient task distribution."
  (buffer (make-array 1024) :type simple-vector)
  (bottom 0 :type fixnum)
  (top 0 :type fixnum)
  (log-size 10 :type fixnum)
  (lock (sb-thread:make-mutex :name "deque-resize-lock")))

(defun make-work-stealing-deque (&optional (initial-capacity 1024))
  "Create a new work-stealing deque with given initial capacity.
   Capacity should be a power of 2 for efficient modular arithmetic."
  (let* ((log-size (max 4 (ceiling (log initial-capacity 2))))
         (capacity (ash 1 log-size)))
    (%make-work-stealing-deque
     :buffer (make-array capacity :initial-element nil)
     :log-size log-size)))

(declaim (inline deque-mask deque-size))

(defun deque-mask (deque)
  "Return mask for modular indexing."
  (1- (length (work-stealing-deque-buffer deque))))

(defun deque-size (deque)
  "Return number of tasks in deque."
  (max 0 (- (work-stealing-deque-bottom deque)
            (work-stealing-deque-top deque))))

(defun deque-push-bottom (deque task)
  "Push a task to the bottom of the deque (local operation, no contention)."
  (let* ((bottom (work-stealing-deque-bottom deque))
         (top (work-stealing-deque-top deque))
         (size (- bottom top))
         (buffer (work-stealing-deque-buffer deque))
         (capacity (length buffer)))
    ;; Resize if needed (rare, amortized O(1))
    (when (>= size (1- capacity))
      (sb-thread:with-mutex ((work-stealing-deque-lock deque))
        (let* ((new-capacity (* capacity 2))
               (new-buffer (make-array new-capacity :initial-element nil))
               (mask (1- capacity)))
          (loop for i from top below bottom
                do (setf (svref new-buffer (logand i (1- new-capacity)))
                         (svref buffer (logand i mask))))
          (setf (work-stealing-deque-buffer deque) new-buffer)
          (setf buffer new-buffer))))
    ;; Store task and increment bottom
    (let ((mask (1- (length buffer))))
      (setf (svref buffer (logand bottom mask)) task)
      ;; Memory barrier to ensure task is visible before bottom update
      (sb-thread:barrier (:write))
      (setf (work-stealing-deque-bottom deque) (1+ bottom))))
  task)

(defun deque-pop-bottom (deque)
  "Pop a task from the bottom of the deque (local operation).
   Returns NIL if deque is empty or stolen."
  (let* ((bottom (1- (work-stealing-deque-bottom deque)))
         (buffer (work-stealing-deque-buffer deque))
         (mask (1- (length buffer))))
    (setf (work-stealing-deque-bottom deque) bottom)
    (sb-thread:barrier (:memory))
    (let ((top (work-stealing-deque-top deque)))
      (if (< top bottom)
          ;; Deque has at least 2 items, safe to pop
          (svref buffer (logand bottom mask))
          ;; Deque has 0 or 1 items, may need to race with stealers
          (progn
            (setf (work-stealing-deque-bottom deque) (1+ bottom))
            (if (= top bottom)
                ;; Exactly one item - try to take it with CAS
                (let ((task (svref buffer (logand bottom mask))))
                  (if (sb-ext:cas (work-stealing-deque-top deque) top (1+ top))
                      task
                      nil))
                ;; Empty
                nil))))))

(defun deque-steal-top (deque)
  "Steal a task from the top of the deque (used by other workers).
   Returns NIL if deque is empty or contended."
  (let ((top (work-stealing-deque-top deque)))
    (sb-thread:barrier (:memory))
    (let* ((bottom (work-stealing-deque-bottom deque))
           (buffer (work-stealing-deque-buffer deque))
           (mask (1- (length buffer))))
      (if (< top bottom)
          ;; Deque non-empty, try to steal
          (let ((task (svref buffer (logand top mask))))
            (if (sb-ext:cas (work-stealing-deque-top deque) top (1+ top))
                task
                nil))
          nil))))
