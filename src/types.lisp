;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-parallel)

;;; Core types for cl-parallel
(deftype cl-parallel-id () '(unsigned-byte 64))
(deftype cl-parallel-status () '(member :ready :active :error :shutdown))
