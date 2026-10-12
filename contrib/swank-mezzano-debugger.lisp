;;; swank-mezzano-debugger.lisp --- Retained Mezzano debugger stops
;;;
;;; This code is in the public domain.

(defpackage #:swank/mezzano-debugger
  (:use #:cl))

(in-package #:swank/mezzano-debugger)

(define-condition protocol-error (error)
  ((reason :initarg :reason :reader protocol-error-reason)))

(defstruct session
  name boot connection controller released-p listener
  (next-handle 0)
  (handles (make-hash-table))
  (objects (make-hash-table :test #'eq))
  (stops (make-hash-table))
  (jobs (make-hash-table :test #'equal)))

(defvar *sessions* (make-hash-table :test #'equal))
(defvar *lock* (mezzano.supervisor:make-mutex 'debugger-sessions))
(defvar *boot* (mezzano.supervisor:current-boot-id))

(defun reject (reason)
  (error 'protocol-error :reason reason))

(defmacro with-lock (&body body)
  `(handler-case
       (mezzano.supervisor:without-footholds
         (mezzano.supervisor:with-mutex (*lock*)
           (retire-old-sessions)
           ,@body))
     (error (condition) (error condition))))

(defmacro reply (&body body)
  `(handler-case
       (list :ok (progn ,@body))
     (protocol-error (condition)
       (list :error (protocol-error-reason condition)))
     (mezzano.debug:debugger-service-error (condition)
       (list :error (mezzano.debug:debugger-service-error-reason condition)))))

(defun current-session (name)
  (let ((session (gethash name *sessions*)))
    (unless (and session
                 (eq (session-boot session)
                     (mezzano.supervisor:current-boot-id))
                 (not (session-released-p session)))
      (reject :expired-session))
    session))

(defun check-connection ()
  (unless (member swank::*emacs-connection* swank::*connections*)
    (reject :closed-connection))
  (when (loop for session being the hash-values of *sessions*
              thereis (eq (session-connection session)
                          swank::*emacs-connection*))
    (reject :connection-attached)))

(defun attach-session (session)
  (when (session-connection session)
    (reject :session-attached))
  (setf (session-connection session) swank::*emacs-connection*
        (session-controller session) (mezzano.debug:make-debugger-controller))
  (session-name session))

(defun close-session-connection (connection)
  (with-lock
    (maphash
     (lambda (name session)
       (declare (ignore name))
       (when (eq (session-connection session) connection)
         (mezzano.debug:close-debugger-controller (session-controller session))
         (setf (session-connection session) nil
               (session-controller session) nil)))
     *sessions*)))

(swank::defslimefun open-session (name)
  "Create a session with a fresh client-generated 256-bit hexadecimal name."
  (reply
    (with-lock
      (unless (and (stringp name) (= (length name) 64)
                   (every (lambda (char) (find char "0123456789abcdef")) name))
        (reject :invalid-session-name))
      (when (gethash name *sessions*) (reject :session-name-used))
      (check-connection)
      (let ((session (make-session
                      :name (copy-seq name)
                      :boot (mezzano.supervisor:current-boot-id))))
        (attach-session session)
        (setf (gethash (session-name session) *sessions*) session)
        (session-name session)))))

(swank::defslimefun resume-session (name)
  "Attach this connection to a session from the current boot."
  (reply
    (with-lock
      (check-connection)
      (attach-session (current-session name)))))

(defun encode-handle (session kind object)
  (when object
    (or (gethash object (session-objects session))
        (let* ((id (incf (session-next-handle session)))
               (token (list kind (session-name session) id)))
          (setf (gethash id (session-handles session)) (cons kind object)
                (gethash object (session-objects session)) token)
          token))))

(defun decode-handle (session kind token)
  (unless (and (consp token) (consp (cdr token)) (consp (cddr token))
               (null (cdddr token))
               (eq (first token) kind)
               (equal (second token) (session-name session)))
    (reject :invalid-handle))
  (let ((entry (gethash (third token) (session-handles session))))
    (unless (and entry (eq (car entry) kind))
      (reject :invalid-handle))
    (cdr entry)))

(defun encode-stop (session handle)
  (when handle
    (let ((id (getf (mezzano.debug:debugger-stop-information handle) :id)))
      (or (gethash id (session-stops session))
          (setf (gethash id (session-stops session))
                (encode-handle session :stop handle))))))

(defun stop-information (session handle)
  (let ((info (mezzano.debug:debugger-stop-information handle)))
    (setf (getf info :parent) (encode-stop session (getf info :parent))
          (getf info :child) (encode-stop session (getf info :child)))
    info))

(defun encode-job (session handle)
  (let ((name (getf (mezzano.debug:evaluation-job-information handle) :name)))
    (or (gethash name (session-jobs session))
        (setf (gethash name (session-jobs session))
              (encode-handle session :job handle)))))

(defun job-information (session handle)
  (let ((info (mezzano.debug:evaluation-job-information handle)))
    (setf (getf info :stops)
          (mapcar (lambda (stop) (encode-stop session stop)) (getf info :stops)))
    info))

(defun command-result (session handle id)
  (let ((result (mezzano.debug:debugger-command-result handle id)))
    (when (eq (getf result :operation) :frames)
      (dolist (entry (getf result :result))
        (setf (getf entry :frame)
              (encode-handle session :frame (getf entry :frame)))))
    result))

(defun release-session (session)
  (when (session-controller session)
    (mezzano.debug:close-debugger-controller (session-controller session)))
  (setf (session-released-p session) t
        (session-connection session) nil
        (session-controller session) nil
        (session-listener session) nil)
  (clrhash (session-handles session))
  (clrhash (session-objects session))
  (clrhash (session-stops session))
  (clrhash (session-jobs session))
  nil)

(defun retire-old-sessions ()
  (let ((boot (mezzano.supervisor:current-boot-id)))
    (unless (eq boot *boot*)
      (maphash (lambda (name session)
                 (declare (ignore name))
                 (release-session session))
               *sessions*)
      (setf *boot* boot))))

(defun ensure-listener (session)
  (or (session-listener session)
      (setf (session-listener session) (mezzano.command-processor:make-listener))))

(defun dispatch (session operation arguments)
  (ecase operation
    (:stops
     (destructuring-bind (&optional include-closed) arguments
       (mapcar (lambda (handle) (encode-stop session handle))
               (mezzano.debug:debugger-stops :include-closed include-closed))))
    (:information
     (destructuring-bind (token) arguments
       (stop-information session (decode-handle session :stop token))))
    (:attach
     (destructuring-bind (token) arguments
       (encode-handle
        session :lease
        (mezzano.debug:attach-debugger-stop
         (decode-handle session :stop token) (session-controller session)))))
    (:submit
     (destructuring-bind (token id operation &optional argument) arguments
       (mezzano.debug:submit-debugger-command
        (decode-handle session :lease token) id operation
        (if (eq operation :locals)
            (decode-handle session :frame argument)
            argument))))
    (:result
     (destructuring-bind (token id) arguments
       (command-result session (decode-handle session :stop token) id)))
    (:release-stop
     (destructuring-bind (token) arguments
       (mezzano.debug:release-debugger-stop (decode-handle session :lease token))
       nil))
    (:start-evaluation
     (destructuring-bind (name source &key (package "CL-USER") (input "") interactive) arguments
       (encode-job session (mezzano.debug:start-evaluation-job
                            name source :package package :input input :interactive interactive))))
    (:listener-information
     (destructuring-bind () arguments
       (mezzano.command-processor:listener-information (ensure-listener session))))
    (:listener-assistance
     (destructuring-bind (source cursor action &key (context :listener) presentation) arguments
       (mezzano.command-processor:assistance (ensure-listener session) source cursor action
                                            :context context :presentation presentation)))
    (:start-listener
     (destructuring-bind (name source &key interactive) arguments
       (encode-job session (mezzano.command-processor:start-listener
                            (ensure-listener session) name source :interactive interactive))))
    (:jobs
     (destructuring-bind () arguments
       (mapcar (lambda (handle) (encode-job session handle))
               (mezzano.debug:evaluation-jobs))))
    (:job-information
     (destructuring-bind (token) arguments
       (job-information session (decode-handle session :job token))))
    (:job-output
     (destructuring-bind (token start &optional end) arguments
       (multiple-value-bind (text end)
           (mezzano.debug:evaluation-job-output
            (decode-handle session :job token) start end)
         (list :text text :end end))))
    (:job-input
     (destructuring-bind (token offset text &key eof) arguments
       (mezzano.debug:supply-evaluation-input
        (decode-handle session :job token) offset text :eof eof)))
    (:interrupt-job
     (destructuring-bind (token id) arguments
       (mezzano.debug:interrupt-evaluation-job
        (decode-handle session :job token) id)))
    (:job-interrupt-result
     (destructuring-bind (token id) arguments
       (mezzano.debug:evaluation-job-interrupt-result
        (decode-handle session :job token) id)))
    (:release-job
     (destructuring-bind (token) arguments
       (mezzano.debug:release-evaluation-job (decode-handle session :job token))
       nil))
    (:release-session
     (when arguments (reject :unexpected-arguments))
     (release-session session))))

(swank::defslimefun request (name operation &rest arguments)
  "Perform a debugger service request using this connection's session."
  (reply
    (with-lock
      (let ((session (current-session name)))
        (unless (eq (session-connection session) swank::*emacs-connection*)
          (reject :wrong-connection))
        (dispatch session operation arguments)))))

(pushnew 'close-session-connection swank::*connection-closed-hook*)

(provide :swank-mezzano-debugger)
