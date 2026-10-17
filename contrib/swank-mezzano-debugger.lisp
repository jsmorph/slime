;;; swank-mezzano-debugger.lisp --- Retained Mezzano debugger stops
;;;
;;; This code is in the public domain.

(defpackage #:swank/mezzano-debugger
  (:use #:cl))

(in-package #:swank/mezzano-debugger)

(defun call-with-connection (function)
  (if (member swank::*emacs-connection* swank::*connections*)
      (funcall function swank::*emacs-connection*)
      (list :error :closed-connection)))

(swank::defslimefun open-session (name)
  "Create a session with a fresh client-generated 256-bit hexadecimal name."
  (call-with-connection
   (lambda (owner) (mezzano.remote-service:open-session name owner))))

(swank::defslimefun resume-session (name)
  "Attach this connection to a session from the current boot."
  (call-with-connection
   (lambda (owner) (mezzano.remote-service:resume-session name owner))))

(swank::defslimefun request (name operation &rest arguments)
  "Perform a debugger service request using this connection's session."
  (call-with-connection
   (lambda (owner) (mezzano.remote-service:request name owner operation arguments))))

(swank::defslimefun transient-request (name operation &rest arguments)
  "Perform one operation, releasing its session attachment before replying."
  (call-with-connection
   (lambda (owner)
     (declare (ignore owner))
     (mezzano.remote-service:transient-request name operation arguments))))

(pushnew 'mezzano.remote-service:close-owner swank::*connection-closed-hook*)

(provide :swank-mezzano-debugger)
